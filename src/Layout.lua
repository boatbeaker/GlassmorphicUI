--!strict
--!native
--!optimize 2

-- Derives output resolution, density warp, grid buffers, and geometry from window size and attributes

local Liquid = require(script.Parent.Liquid)
local Config = require(script.Parent.Config)
local Attributes = require(script.Parent.Attributes)
local GlassObject = require(script.Parent.GlassObject)

type GlassObject = GlassObject.GlassObject

local Layout = {}

-- Recomputes size and attribute-derived state; grid warm-starts from previous for temporal smoothing
function Layout.update(glassObject: GlassObject)
	local Window = glassObject.Window
	if not Window then
		return
	end
	glassObject.PendingLayout = false

	local absoluteSize = Window.AbsoluteSize
	-- Round for cache sharing across float-size variations
	local winW, winH = math.round(absoluteSize.X), math.round(absoluteSize.Y)
	if winW <= 0 or winH <= 0 then
		return
	end

	-- Scale-expressed blur radius changes on resize
	Attributes.updateWindowBlur(glassObject)

	local params = Attributes.parseLiquidParams(glassObject, winW, winH)
	glassObject.LiquidParams = params

	-- Aspect-fit output resolution under attribute cap and ladder
	local outputCap = math.min(params.maxOutputResolution, glassObject.LadderCap)
	local maxAxis = math.max(winW, winH)
	local outputScale = maxAxis / math.min(outputCap, maxAxis)
	local outW = math.max(math.floor(winW / outputScale + 0.5), 1)
	local outH = math.max(math.floor(winH / outputScale + 0.5), 1)
	local outputResolution = Vector2.new(outW, outH)

	-- Source grid over the window rect, one cell per fixed square of
	-- screen pixels, so sampling cost scales with window area. Refraction
	-- is inward-only; on windows smaller than its fixed pixel reach the
	-- fetches clamp at the far edge instead of leaving the grid.
	local samplerSize = Config.SAMPLING_CELL_SIZE
	local gridW = math.max(winW // samplerSize, 1)
	local gridH = math.max(winH // samplerSize, 1)
	local gridResolution = Vector2.new(gridW, gridH)

	-- Sampling density is allocated where refracted fetches land, scanned
	-- over the true window shape (see Liquid.buildWarp). The build is
	-- synchronous and expensive, so it's skipped when the relayout changes
	-- none of its inputs.
	local uniformWarp = Config.DEBUG_UNIFORM_WARP
	local warpKey = Liquid.warpKey(gridW, gridH, winW, winH, params, Config.EDGE_DENSITY_BOOST)
		.. (if uniformWarp then ":uniform" else "")
	if warpKey ~= glassObject.WarpKey then
		debug.profilebegin("GlassWarpBuild")
		local gridPosX, warpLutX, gridPosY, warpLutY =
			Liquid.buildWarp(gridW, gridH, winW, winH, params, Config.EDGE_DENSITY_BOOST, uniformWarp)
		glassObject.GridPosX, glassObject.WarpLutX = gridPosX, warpLutX
		glassObject.GridPosY, glassObject.WarpLutY = gridPosY, warpLutY
		glassObject.WarpKey = warpKey
		glassObject.MapsGeneration += 1
		debug.profileend()
	end

	if gridResolution ~= glassObject.Resolution then
		local pixelCount = gridW * gridH
		local bufferLength = pixelCount * 4
		local newPixels = buffer.create(bufferLength)
		Liquid.resampleGridBilinear(
			glassObject.Pixels,
			glassObject.Resolution.X,
			glassObject.Resolution.Y,
			newPixels,
			gridW,
			gridH
		)
		glassObject.Pixels = newPixels
		glassObject.Scratch = buffer.create(bufferLength)
		glassObject.PixelCount = pixelCount
		glassObject.Resolution = gridResolution
		glassObject.ResolutionX = gridW
		if glassObject.PixelIndex >= bufferLength then
			glassObject.PixelIndex = 0
		end
	end

	-- OutputResolution starts at zero and real resolutions are at least
	-- 1x1, so this also covers the first layout's buffer creation
	if outputResolution ~= glassObject.OutputResolution then
		glassObject.OutPixels = buffer.create(outW * outH * 4)
		glassObject.OutputResolution = outputResolution
	end

	local rawField = Config.DEBUG_RAW_DISTANCE_FIELD
	local key = Liquid.geometryKey(winW, winH, outW, outH, params, rawField)
	local geometry = glassObject.Geometry
	if not geometry or geometry.Key ~= key then
		if geometry then
			Liquid.releaseGeometry(geometry)
		end
		glassObject.Geometry = Liquid.acquireGeometry(winW, winH, outW, outH, params, key, rawField)
		glassObject.MapsGeneration += 1
	end

	-- Any in-flight reconstruction is against stale mappings now. Dropping
	-- ParallelJob discards late worker chunks (results are only read
	-- through it), and clearing the finish token cancels an in-flight
	-- finish thread before it uploads.
	glassObject.ReconJob = nil
	glassObject.ParallelJob = nil
	glassObject.FinishToken = nil
	glassObject.ForceRecon = true
end

-- Debounces layout-affecting changes: keeps rendering through the current
-- maps and rebuilds once the values settle, so a tween doesn't rebuild
-- the warp and geometry every frame.
function Layout.request(glassObject: GlassObject)
	if glassObject.Geometry then
		if not glassObject.PendingLayout then
			glassObject.PendingLayout = true
			glassObject.FirstLayoutRequestClock = os.clock()
		end
		glassObject.LastLayoutRequestClock = os.clock()
	else
		Layout.update(glassObject)
	end
end

-- Step-down ladder: halves the output resolution cap down to a floor
-- instead of retrying a size the EditableImage budget already refused.
-- At the floor, Recon warns once and keeps retrying at the floor size.
function Layout.stepDownResolution(glassObject: GlassObject)
	-- Halve from the size that was just refused; it already reflects every cap
	local refused = math.max(glassObject.OutputResolution.X, glassObject.OutputResolution.Y)
	if refused > Config.MIN_OUTPUT_RESOLUTION then
		glassObject.LadderCap = math.max(math.floor(refused / 2), Config.MIN_OUTPUT_RESOLUTION)
		Layout.update(glassObject)
	end
end

return Layout
