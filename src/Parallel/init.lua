--!strict

-- Actor pool for parallel reconstruction. Rows split across workers, chunks drip-fed to fit frame budget. Results come back per-pass through SharedTable

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local Liquid = require(script.Parent.Liquid)
local Config = require(script.Parent.Config)
local GlassObject = require(script.Parent.GlassObject)

type GlassObject = GlassObject.GlassObject
type ParallelPending = GlassObject.ParallelPending
type ParallelWorkerState = GlassObject.ParallelWorkerState

local WORKER_START_TIMEOUT = 5 -- seconds for the Ready handshake

-- Consecutive timeouts before pool latches broken
local TIMEOUTS_BEFORE_BROKEN = 3

local Parallel = {}

local pool: { Actor } = {}
local container: Folder? = nil
local poolBroken = false
local poolInitializing = false
local consecutiveTimeouts = 0
local nextWindowId = 0
local nextPassId = 0
-- What each actor's caches hold; rebuilt pool starts with clean records
local sentGenerations: { [Actor]: { [number]: number } } = {}
local warnedFallbackClasses: { [string]: boolean } = {}

-- Warn once per failure class; transient and permanent failures are independent
local function warnFallbackOnce(class: string, reason: string)
	if warnedFallbackClasses[class] then
		return
	end
	warnedFallbackClasses[class] = true
	warn(
		"GlassmorphicUI: parallel reconstruction unavailable ("
			.. reason
			.. "), falling back to synchronous reconstruction"
	)
end

local function createWorker(parent: Folder): Actor
	local template = script:FindFirstChild("WorkerTemplate")
	assert(template and template:IsA("Actor"), "GlassmorphicUI is missing its WorkerTemplate")
	local actor = template:Clone()

	local workerScript = actor:FindFirstChild("WorkerClient") :: Script
	assert(
		workerScript and workerScript:IsA("Script"),
		"GlassmorphicUI's WorkerTemplate is missing its WorkerClient script"
	)

	-- The clone loses its place in the library tree, so hand it an explicit
	-- reference to require from its own VM (see WorkerTemplate/Worker.lua)
	local libraryRef = Instance.new("ObjectValue")
	libraryRef.Name = "LibraryRef"
	libraryRef.Value = script.Parent
	libraryRef.Parent = workerScript

	actor.Parent = parent
	workerScript.Disabled = false

	return actor
end

-- Grows the pool to the configured worker count. Yields during the Ready
-- handshake, so ensureWarm runs it in its own thread. Throws on failure;
-- the caller latches and warns.
local function growPool()
	if not RunService:IsRunning() or RunService:IsServer() then
		-- The library is client-only (it samples through the LocalPlayer's
		-- PlayerGui), so the workers ship a Client entry script only
		error("workers need a running client session")
	end
	local bin = (Players.LocalPlayer :: Player):WaitForChild("PlayerScripts")

	if not container then
		local folder = Instance.new("Folder")
		folder.Name = "GlassmorphicUIWorkers"
		folder.Parent = bin
		container = folder
	end
	local folder = container :: Folder

	local created: { Actor } = {}
	for _ = #pool + 1, Config.PARALLEL_WORKER_COUNT do
		created[#created + 1] = createWorker(folder)
	end

	-- Workers set the Ready attribute from their serial startup after
	-- binding their message handlers; messages sent before that are lost.
	-- Ready workers are adopted into the pool as they come up; any still
	-- not ready at the deadline are destroyed.
	local deadline = os.clock() + WORKER_START_TIMEOUT
	while #created > 0 do
		for index = #created, 1, -1 do
			if created[index]:GetAttribute("Ready") == true then
				pool[#pool + 1] = created[index]
				table.remove(created, index)
			end
		end
		if #created == 0 then
			break
		end
		if os.clock() > deadline then
			local missing = #created
			for _, actor in created do
				actor:Destroy()
			end
			error(missing .. " worker(s) did not start within " .. WORKER_START_TIMEOUT .. " seconds")
		end
		task.wait()
	end
end

-- Non-yielding pool check for the scatter path, which runs during
-- Heartbeat and can never wait. The first call kicks the yielding startup
-- off in its own thread; until workers are ready, passes take the
-- synchronous route.
local function ensureWarm(): boolean
	if poolBroken then
		return false
	end

	-- Prune workers whose actors were destroyed (a cleanup script wiping
	-- PlayerScripts), so the pool rebuilds instead of messaging destroyed
	-- actors
	if container and container.Parent == nil then
		container = nil
	end
	for index = #pool, 1, -1 do
		if container == nil or pool[index].Parent == nil then
			sentGenerations[pool[index]] = nil
			table.remove(pool, index)
		end
	end

	if #pool < Config.PARALLEL_WORKER_COUNT and not poolInitializing then
		poolInitializing = true
		task.spawn(function()
			local problem: string? = nil
			local success = xpcall(growPool, function(message)
				problem = tostring(message)
			end)
			poolInitializing = false
			if not success then
				-- Latch the permanent fallback only when the environment
				-- cannot run workers at all; if some workers did start, the
				-- next call retries the deficit
				if #pool == 0 then
					poolBroken = true
				end
				warnFallbackOnce("startup", tostring(problem))
			end
		end)
	end
	return #pool > 0
end

-- Whether the next pass for this window should go to the pool. Kicks the
-- pool warmup on first use.
function Parallel.shouldUse(glassObject: GlassObject): boolean
	if
		not Config.PARALLEL_ENABLED
		or Config.DEBUG_SAMPLING_HEATMAP
		or Config.DEBUG_OVERLAY ~= nil
		or Config.DEBUG_BILINEAR_FETCH
		or poolBroken
	then
		return false
	end
	-- An opaque window renders pure tint with no grid reads; the pass is
	-- cheaper than the message copies
	if GlassObject.isOpaque(glassObject) then
		return false
	end
	-- A window mid-resize or mid-tween stays synchronous: every debounced
	-- relayout bumps the maps generation, so each scattered pass would
	-- resend the rebuilt maps to every worker, costing more than the pass
	-- saves. The clock check keeps the pool off until the tween settles.
	if glassObject.PendingLayout or os.clock() - glassObject.LastLayoutRequestClock < Config.PARALLEL_RESIZE_SETTLE then
		return false
	end
	local outputResolution = glassObject.OutputResolution
	if outputResolution.X * outputResolution.Y < Config.PARALLEL_MIN_OUTPUT_PIXELS then
		return false
	end
	return ensureWarm()
end

-- Sends one chunk of a worker's band. The heavy inputs ride along only on
-- the chunks that need them: the maps when the worker's cache generation
-- is stale, the grid on the pass's first chunk to that worker.
local function sendChunk(
	glassObject: GlassObject,
	pending: ParallelPending,
	state: ParallelWorkerState,
	firstOfPass: boolean
): boolean
	local job = pending.Job
	local rowCount = math.min(state.RowEnd - state.RowNext, math.max(Config.PARALLEL_CHUNK_PIXELS // job.OutW, 1))
	state.AwaitingRows = rowCount

	local actor = state.Actor
	local generation = glassObject.MapsGeneration
	local tracked = sentGenerations[actor]
	if not tracked then
		tracked = {}
		sentGenerations[actor] = tracked
	end
	local sendMaps = tracked[glassObject.ParallelId] ~= generation

	-- Absent optional args travel as false, not nil: a nil hole in the
	-- middle of a vararg pack is not guaranteed to survive serialization
	local success, problem = pcall(function()
		actor:SendMessage(
			"Recon",
			pending.Results,
			state.Slot,
			if firstOfPass then job.Grid else false,
			if sendMaps then job.Disp else false,
			if sendMaps then job.Aux else false,
			if sendMaps then job.WarpX else false,
			if sendMaps then job.WarpY else false,
			{
				WindowId = glassObject.ParallelId,
				PassId = pending.PassId,
				Generation = generation,
				RowStart = state.RowNext,
				RowCount = rowCount,
				GridW = job.GridW,
				GridH = job.GridH,
				OutW = job.OutW,
				OutH = job.OutH,
				StepX = job.StepX,
				StepY = job.StepY,
				TintR = job.TintR,
				TintG = job.TintG,
				TintB = job.TintB,
				TintAlpha = job.TintAlpha,
				RedScale = job.RedScale,
				BlueScale = job.BlueScale,
			}
		)
	end)
	if not success then
		-- Most likely an actor destroyed mid-frame; ensureWarm prunes it
		-- before the next scatter
		warnFallbackOnce("send", tostring(problem))
		return false
	end
	if sendMaps then
		tracked[glassObject.ParallelId] = generation
	end
	return true
end

-- Starts one banded pass: splits the output rows into a band per worker
-- and sends every worker its first chunk. All first chunks go out in this
-- same frame, and SendMessage copies the grid on send, so every band
-- snapshots the same grid state. Returns nil when the pool cannot take
-- the pass, in which case the caller runs the synchronous route.
function Parallel.scatter(glassObject: GlassObject, job: Liquid.ReconJob): ParallelPending?
	local workerCount = math.min(#pool, job.OutH)
	if workerCount == 0 then
		return nil
	end
	if glassObject.ParallelId == 0 then
		nextWindowId += 1
		glassObject.ParallelId = nextWindowId
	end
	nextPassId += 1

	local results = SharedTable.new()
	local pending: ParallelPending = {
		PassId = nextPassId,
		Job = job,
		Results = results,
		Workers = table.create(workerCount),
		FramesWaited = 0,
	}

	for index = 1, workerCount do
		local state: ParallelWorkerState = {
			Actor = pool[index],
			Slot = index,
			RowNext = (index - 1) * job.OutH // workerCount,
			RowEnd = index * job.OutH // workerCount,
			AwaitingRows = 0,
		}
		pending.Workers[index] = state
		if not sendChunk(glassObject, pending, state, true) then
			-- Chunks already sent write into slots nobody will read; the
			-- abandoned pending record is the cancellation
			return nil
		end
	end

	return pending
end

-- Handles one worker's failure sentinel. Stale-cache failures come from a
-- worker that lost its caches (a rebuilt pool clone); clearing the
-- tracking makes the next pass resend everything, so they never latch the
-- pool broken. Anything else is a kernel error that would recur on every
-- retry, so the pool latches instead of warning once and failing forever.
local function handleWorkerFailure(glassObject: GlassObject, state: ParallelWorkerState, message: string)
	if string.find(message, "stale-cache", 1, true) then
		local tracked = sentGenerations[state.Actor]
		if tracked then
			tracked[glassObject.ParallelId] = nil
		end
		warnFallbackOnce("stale-cache", "a worker lost its cached maps; the next pass resends them")
	else
		poolBroken = true
		warnFallbackOnce("worker-error", "worker error: " .. message)
	end
end

-- Checks one in-flight pass and drip-feeds the next chunks. "done" means
-- every band was validated and spliced into the job's output buffer;
-- "failed" means the caller should force a synchronous re-render.
function Parallel.poll(glassObject: GlassObject, pending: ParallelPending): "pending" | "done" | "failed"
	local results = pending.Results
	local job = pending.Job
	local stride = job.OutW * 4
	local progressed = false
	local remaining = false

	for _, state in pending.Workers do
		if state.AwaitingRows == 0 then
			continue
		end
		local payload = results[state.Slot]
		if payload == nil then
			remaining = true
			continue
		end
		if type(payload) ~= "string" or #payload ~= state.AwaitingRows * stride then
			handleWorkerFailure(glassObject, state, tostring(results.error))
			return "failed"
		end

		buffer.writestring(job.Out, state.RowNext * stride, payload)
		results[state.Slot] = nil
		state.RowNext += state.AwaitingRows
		state.AwaitingRows = 0
		progressed = true

		if state.RowNext < state.RowEnd then
			if not sendChunk(glassObject, pending, state, false) then
				return "failed"
			end
			remaining = true
		end
	end

	if not remaining then
		consecutiveTimeouts = 0
		return "done"
	end

	if progressed then
		pending.FramesWaited = 0
	else
		pending.FramesWaited += 1
		if pending.FramesWaited >= Config.PARALLEL_TIMEOUT_FRAMES then
			consecutiveTimeouts += 1
			if consecutiveTimeouts >= TIMEOUTS_BEFORE_BROKEN then
				poolBroken = true
			end
			warnFallbackOnce("timeout", "a pass made no progress for " .. Config.PARALLEL_TIMEOUT_FRAMES .. " frames")
			return "failed"
		end
	end
	return "pending"
end

-- Clears a removed window's footprint in the worker caches, so the maps
-- do not outlive it.
function Parallel.forget(glassObject: GlassObject)
	local windowId = glassObject.ParallelId
	if windowId == 0 then
		return
	end
	for _, actor in pool do
		local tracked = sentGenerations[actor]
		if tracked and tracked[windowId] ~= nil then
			tracked[windowId] = nil
			pcall(function()
				actor:SendMessage("Forget", windowId)
			end)
		end
	end
end

return Parallel
