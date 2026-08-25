--!strict
--!native
--!optimize 2

-- Stage B: budgeted sampling, one grid cell per call. Sequential walk prevents comb ghosting

local Dependencies = require(script.Parent.Dependencies)
local Config = require(script.Parent.Config)
local GlassObject = require(script.Parent.GlassObject)

type GlassObject = GlassObject.GlassObject

local PixelColorApproximation = Dependencies.PixelColorApproximation

local Sampler = {}

function Sampler.processNextPixel(glassObject: GlassObject, skipTween: boolean?): boolean
	-- Kept current by Window's watcher; no per-pixel Instance reads
	if not glassObject.Parented then
		return false
	end

	local Pixels, PixelIndex = glassObject.Pixels, glassObject.PixelIndex
	local bufferLength = glassObject.PixelCount * 4

	local gridPosX, gridPosY = glassObject.GridPosX, glassObject.GridPosY
	if not gridPosX or not gridPosY then
		return false
	end

	-- Sample at this grid cell's warped center: denser where refracted
	-- fetches concentrate, with a per-row x warp so the dense band follows
	-- the window shape.
	--
	-- Sample below pane not window to avoid reading pane's own glass back into grid
	local resolutionX = glassObject.ResolutionX
	local indexFloor4 = PixelIndex // 4
	local xIndex = indexFloor4 % resolutionX
	local rowOffset = (indexFloor4 // resolutionX) * 4
	local posX = buffer.readf32(gridPosX, PixelIndex)
	local posY = buffer.readf32(gridPosY, rowOffset)

	-- Footprint is local cell spacing; detail finer than spacing gets averaged
	local spacingX = math.max(
		if xIndex > 0 then posX - buffer.readf32(gridPosX, PixelIndex - 4) else 0,
		if xIndex < resolutionX - 1 then buffer.readf32(gridPosX, PixelIndex + 4) - posX else 0
	)
	local lastRowOffset = (glassObject.PixelCount // resolutionX - 1) * 4
	local spacingY = math.max(
		if rowOffset > 0 then posY - buffer.readf32(gridPosY, rowOffset - 4) else 0,
		if rowOffset < lastRowOffset then buffer.readf32(gridPosY, rowOffset + 4) - posY else 0
	)

	-- XY form returns unpacked channels; no Vector2 or table allocation
	local sampleR, sampleG, sampleB = PixelColorApproximation:GetColorXY(
		posX + glassObject.WindowPositionX,
		posY + glassObject.WindowPositionY,
		glassObject.Pane,
		math.max(spacingX, spacingY)
	)

	-- Grid keeps raw backdrop colors; tint applied during reconstruction
	if skipTween then
		buffer.writeu8(Pixels, PixelIndex, math.clamp(math.round(sampleR * 255), 0, 255))
		buffer.writeu8(Pixels, PixelIndex + 1, math.clamp(math.round(sampleG * 255), 0, 255))
		buffer.writeu8(Pixels, PixelIndex + 2, math.clamp(math.round(sampleB * 255), 0, 255))
		glassObject.GridWritesSinceRecon += 1
	else
		local smoothing = Config.TEMPORAL_SMOOTHING
		local prevR = buffer.readu8(Pixels, PixelIndex)
		local prevG = buffer.readu8(Pixels, PixelIndex + 1)
		local prevB = buffer.readu8(Pixels, PixelIndex + 2)
		local newR = math.clamp(math.round(prevR + (sampleR * 255 - prevR) * smoothing), 0, 255)
		local newG = math.clamp(math.round(prevG + (sampleG * 255 - prevG) * smoothing), 0, 255)
		local newB = math.clamp(math.round(prevB + (sampleB * 255 - prevB) * smoothing), 0, 255)
		-- Only real changes retrigger recon; once smoothing converges, pipeline stops
		if newR ~= prevR or newG ~= prevG or newB ~= prevB then
			buffer.writeu8(Pixels, PixelIndex, newR)
			buffer.writeu8(Pixels, PixelIndex + 1, newG)
			buffer.writeu8(Pixels, PixelIndex + 2, newB)
			glassObject.GridWritesSinceRecon += 1
		end
	end

	PixelIndex += 4
	if PixelIndex >= bufferLength then
		PixelIndex = 0
	end

	glassObject.PixelIndex = PixelIndex
	return true
end

return Sampler
