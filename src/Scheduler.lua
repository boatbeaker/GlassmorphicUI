--!strict
--!native
--!optimize 2

-- Per-frame loop: sampling and liquid stages each get time budget, round-robin across windows

local Liquid = require(script.Parent.Liquid)
local Config = require(script.Parent.Config)
local GlassObject = require(script.Parent.GlassObject)
local Sampler = require(script.Parent.Sampler)
local Layout = require(script.Parent.Layout)
local Recon = require(script.Parent.Recon)

type GlassObject = GlassObject.GlassObject

-- Round-robin cursors persist; budget rotates instead of always starting first
local glassObjectUpdateIndex = 1
local liquidUpdateIndex = 1

local Scheduler = {}

function Scheduler.totalUpdate(glassObject: GlassObject)
	-- Complete sync update: layout, geometry, full sampling, full reconstruction
	debug.profilebegin("GlassTotalUpdate")
	Layout.update(glassObject)
	local geometry = glassObject.Geometry
	if geometry and not geometry.Ready then
		Liquid.stepGeometry(geometry, math.huge)
		glassObject.ForceRecon = true
	end

	-- Opaque window: skip sampling
	if not GlassObject.isOpaque(glassObject) then
		-- Stop on wraparound or when sampler cannot progress
		local startPixel = glassObject.PixelIndex
		while Sampler.processNextPixel(glassObject, true) do
			if glassObject.PixelIndex == startPixel then
				break
			end
		end
	end

	-- A total update re-snapshots from scratch, so drop any in-flight pass
	-- and cancel the finish thread before it uploads over this fresher
	-- render
	glassObject.ReconJob = nil
	glassObject.ParallelJob = nil
	glassObject.FinishToken = nil
	Recon.advance(glassObject, math.huge, true)
	debug.profileend()
end

-- Per-frame liquid work for one window: apply a settled debounced resize,
-- advance the chunked geometry build, then advance or retrigger the
-- reconstruction pass, all bounded by the shared deadline.
local function stepLiquid(glassObject: GlassObject, deadline: number)
	glassObject.FramesSinceRecon += 1

	-- Debounce with a max wait, so a never-settling tween still gets
	-- periodic layouts instead of sampling through stale geometry forever
	if glassObject.PendingLayout then
		local now = os.clock()
		if
			now - glassObject.LastLayoutRequestClock >= Config.RESIZE_DEBOUNCE
			or now - glassObject.FirstLayoutRequestClock >= Config.RESIZE_MAX_WAIT
		then
			Layout.update(glassObject)
		end
	end

	local geometry = glassObject.Geometry
	if not geometry then
		return
	end
	if not geometry.Ready then
		debug.profilebegin("GlassGeometry")
		local geometryReady = Liquid.stepGeometry(geometry, deadline)
		debug.profileend()
		if geometryReady then
			glassObject.ForceRecon = true
		else
			return
		end
	end

	-- A fresh pass starts whenever the grid changed at all. Zero writes
	-- means the snapshot would reproduce the image already on screen, so
	-- only then does reconstruction idle.
	Recon.advance(glassObject, deadline, glassObject.ForceRecon or glassObject.GridWritesSinceRecon > 0)
end

function Scheduler.update()
	local glassObjects = GlassObject.list
	local totalGlassObjects = #glassObjects
	if totalGlassObjects == 0 then
		return
	end

	-- Stage B: PCA samples round-robin until time is up. An object whose
	-- walk comes back around to its starting cell has refreshed every cell
	-- and is done for the frame.
	local sampleDeadline = os.clock() + Config.SAMPLE_TIME_BUDGET
	local updateIndex = glassObjectUpdateIndex
	local idleStreak = 0
	local frameStartIndex: { [GlassObject]: number } = {}
	local refreshed: { [GlassObject]: boolean } = {}
	local sampleCounts: { [GlassObject]: number } = {}
	debug.profilebegin("GlassSampling")
	while os.clock() < sampleDeadline do
		local glassObject = glassObjects[updateIndex]
		local progressed = false
		-- Opaque windows render pure tint and never read the sampled
		-- grid, so they take none of the sampling budget
		if glassObject and not refreshed[glassObject] and not GlassObject.isOpaque(glassObject) then
			if frameStartIndex[glassObject] == nil then
				frameStartIndex[glassObject] = glassObject.PixelIndex
			end
			progressed = Sampler.processNextPixel(glassObject, false)
			if progressed then
				sampleCounts[glassObject] = (sampleCounts[glassObject] or 0) + 1
				if glassObject.PixelIndex == frameStartIndex[glassObject] then
					refreshed[glassObject] = true
				end
			end
		end
		if progressed then
			idleStreak = 0
		else
			-- Unparented, not laid out yet, or already fully refreshed.
			-- A full idle round means no object can progress, so stop.
			idleStreak += 1
			if idleStreak >= totalGlassObjects then
				break
			end
		end
		updateIndex += 1

		if updateIndex > totalGlassObjects then
			updateIndex = 1
		end
	end
	debug.profileend()
	glassObjectUpdateIndex = updateIndex

	-- Publish every window's share of the frame's samples, zeros included,
	-- so the debug stats never show a stale count
	for _, glassObject in glassObjects do
		glassObject.SamplesLastFrame = sampleCounts[glassObject] or 0
	end

	-- Stages A, C, and D run debounced layouts, chunked geometry builds,
	-- and chunked reconstruction, round-robin under their own time budget.
	debug.profilebegin("GlassLiquid")
	local liquidDeadline = os.clock() + Config.LIQUID_TIME_BUDGET
	local liquidIndex = liquidUpdateIndex
	for _ = 1, totalGlassObjects do
		if liquidIndex > totalGlassObjects then
			liquidIndex = 1
		end
		local glassObject = glassObjects[liquidIndex]
		liquidIndex += 1
		if glassObject then
			stepLiquid(glassObject, liquidDeadline)
		end
		if os.clock() >= liquidDeadline then
			break
		end
	end
	debug.profileend()
	liquidUpdateIndex = liquidIndex
end

return Scheduler
