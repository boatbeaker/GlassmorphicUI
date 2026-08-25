--!strict
--!native
--!optimize 2

-- Worker body: reconstructs row chunks. Only heavy inputs sent once; buffers cached per window and pass

type MapsEntry = {
	Generation: number,
	Disp: buffer,
	Aux: buffer,
	WarpX: buffer,
	WarpY: buffer,
}

type GridEntry = {
	PassId: number,
	Grid: buffer,
}

return function(workerScript: Script)
	local actor = workerScript:GetActor()
	if actor == nil then
		-- A stray copy running outside an Actor.
		return
	end

	local libraryRef = workerScript:WaitForChild("LibraryRef") :: ObjectValue
	local library = libraryRef.Value :: Instance
	local Liquid = require(library:WaitForChild("Liquid") :: ModuleScript) :: any

	local mapsCache: { [number]: MapsEntry } = {}
	local gridCache: { [number]: GridEntry } = {}
	-- One full-size output scratch per worker VM, reused across chunks and
	-- windows: chunk results are copied out as strings immediately, so the
	-- scratch's contents never need to survive between messages. Full size
	-- keeps the reconstruction's absolute row offsets valid.
	local outScratch: buffer? = nil

	actor:BindToMessageParallel("Recon", function(
		results: SharedTable,
		slot: number,
		-- Absent optional inputs arrive as false, not nil (see the
		-- dispatcher's sendChunk)
		grid: buffer | false,
		disp: buffer | false,
		aux: buffer | false,
		warpX: buffer | false,
		warpY: buffer | false,
		scalars: { [string]: any }
	)
		debug.profilebegin("GlassWorkerChunk")
		local success, problem = pcall(function()
			local windowId = scalars.WindowId

			-- The heavy inputs ride along only when the dispatcher
			-- believes this worker does not hold them yet
			if disp and aux and warpX and warpY then
				mapsCache[windowId] = {
					Generation = scalars.Generation,
					Disp = disp,
					Aux = aux,
					WarpX = warpX,
					WarpY = warpY,
				}
			end
			if grid then
				gridCache[windowId] = { PassId = scalars.PassId, Grid = grid }
			end

			local maps = mapsCache[windowId]
			local gridEntry = gridCache[windowId]
			if not maps or maps.Generation ~= scalars.Generation then
				error("stale-cache: maps generation mismatch")
			end
			if not gridEntry or gridEntry.PassId ~= scalars.PassId then
				error("stale-cache: grid pass mismatch")
			end

			local outW, outH = scalars.OutW, scalars.OutH
			local outLength = outW * outH * 4
			local scratch = outScratch
			local out: buffer
			if scratch and buffer.len(scratch) == outLength then
				out = scratch
			else
				out = buffer.create(outLength)
				outScratch = out
			end

			local rowStart, rowCount = scalars.RowStart, scalars.RowCount
			local job = {
				Out = out,
				Disp = maps.Disp,
				Aux = maps.Aux,
				Grid = gridEntry.Grid,
				GridW = scalars.GridW,
				GridH = scalars.GridH,
				OutW = outW,
				OutH = outH,
				StepX = scalars.StepX,
				StepY = scalars.StepY,
				WarpX = maps.WarpX,
				WarpY = maps.WarpY,
				TintR = scalars.TintR,
				TintG = scalars.TintG,
				TintB = scalars.TintB,
				TintAlpha = scalars.TintAlpha,
				RedScale = scalars.RedScale,
				BlueScale = scalars.BlueScale,
				-- The finish stages run on the main thread, so their
				-- scalars never travel here
				BlurSigma = 0,
				FresnelIntensity = 0,
				RimEnabled = false,
				Row = rowStart,
				RowEnd = rowStart + rowCount,
			}
			debug.profilebegin("GlassWorkerRecon")
			Liquid.reconstructRows(job, math.huge)
			debug.profileend()

			-- One copy into the string, then a second inside the
			-- SharedTable assignment
			debug.profilebegin("GlassWorkerResult")
			results[slot] = buffer.readstring(out, rowStart * outW * 4, rowCount * outW * 4)
			debug.profileend()
		end)

		if not success then
			results.error = tostring(problem)
			results[slot] = false
		end
		debug.profileend()
	end)

	-- The dispatcher sends this when a window is removed, so the cached
	-- maps do not outlive it
	actor:BindToMessageParallel("Forget", function(windowId: number)
		mapsCache[windowId] = nil
		gridCache[windowId] = nil
	end)

	-- Signal readiness only after the message handlers are bound; messages
	-- sent before binding would be lost.
	actor:SetAttribute("Ready", true)
end
