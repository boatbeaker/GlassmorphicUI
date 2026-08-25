--!strict

--[[
	Shared buffer helpers for the test suite. All coordinates are 0-based
	to match the pipeline's u8 RGBA buffer layout.

	Tests require the library's pure submodules (Liquid, Frost, Composite,
	Config) directly. The library root cannot load here: run-in-roblox
	executes in Studio edit mode, and requiring the root pulls in
	PixelColorApproximation, which waits forever on LocalPlayer.
]]

local Helpers = {}

function Helpers.resolveLibrary(): Instance
	return game:GetService("ReplicatedStorage"):WaitForChild("GlassmorphicUI")
end

-- Builds a width*height*4 u8 RGBA buffer from a per-pixel fill function
-- returning four 0-255 channel values.
function Helpers.makeBuffer(
	width: number,
	height: number,
	fillFn: (x: number, y: number) -> (number, number, number, number)
): buffer
	local pixels = buffer.create(width * height * 4)
	for y = 0, height - 1 do
		for x = 0, width - 1 do
			local base = (y * width + x) * 4
			local r, g, b, a = fillFn(x, y)
			buffer.writeu8(pixels, base, r)
			buffer.writeu8(pixels, base + 1, g)
			buffer.writeu8(pixels, base + 2, b)
			buffer.writeu8(pixels, base + 3, a)
		end
	end
	return pixels
end

-- Builds a rim/mask aux buffer in the geometry bake's layout: u8 fresnel,
-- u8 glare, u8 mask alpha, one pad byte per pixel.
function Helpers.makeAux(
	width: number,
	height: number,
	fillFn: (x: number, y: number) -> (number, number, number)
): buffer
	local aux = buffer.create(width * height * 4)
	for y = 0, height - 1 do
		for x = 0, width - 1 do
			local base = (y * width + x) * 4
			local fresnel, glare, mask = fillFn(x, y)
			buffer.writeu8(aux, base, fresnel)
			buffer.writeu8(aux, base + 1, glare)
			buffer.writeu8(aux, base + 2, mask)
			buffer.writeu8(aux, base + 3, 0)
		end
	end
	return aux
end

-- Reads one channel (0 = R .. 3 = A) at pixel (x, y).
function Helpers.channelAt(pixels: buffer, width: number, x: number, y: number, channel: number): number
	return buffer.readu8(pixels, (y * width + x) * 4 + channel)
end

function Helpers.clone(pixels: buffer): buffer
	local copy = buffer.create(buffer.len(pixels))
	buffer.copy(copy, 0, pixels)
	return copy
end

-- Largest per-byte absolute difference between two equal-length buffers.
function Helpers.maxDifference(a: buffer, b: buffer): number
	assert(buffer.len(a) == buffer.len(b), "buffers differ in length")
	local worst = 0
	for i = 0, buffer.len(a) - 1 do
		local difference = math.abs(buffer.readu8(a, i) - buffer.readu8(b, i))
		if difference > worst then
			worst = difference
		end
	end
	return worst
end

-- A deterministic, non-constant fill so the frost sees realistic data.
function Helpers.patternFill(x: number, y: number): (number, number, number, number)
	return (x * 7 + y * 13) % 256, (x * 3 + y * 29) % 256, (x + y * 5) % 256, (x * 11 + y * 2) % 256
end

export type FinishJobOptions = {
	out: buffer,
	aux: buffer,
	outW: number,
	outH: number,
	tintR: number?,
	tintG: number?,
	tintB: number?,
	tintAlpha: number?,
	blurSigma: number?,
	fresnelIntensity: number?,
	rimEnabled: boolean?,
}

-- Builds a ReconJob for the finish stages. Frost and Composite read only
-- Out, Aux, OutW, OutH, the tint, BlurSigma, FresnelIntensity, and
-- RimEnabled; the reconstruction-stage fields are inert placeholders that
-- keep the record a complete ReconJob.
function Helpers.makeFinishJob(options: FinishJobOptions)
	return {
		Out = options.out,
		Disp = buffer.create(options.outW * options.outH * 4),
		Aux = options.aux,
		Grid = buffer.create(4),
		GridW = 1,
		GridH = 1,
		OutW = options.outW,
		OutH = options.outH,
		StepX = 1,
		StepY = 1,
		WarpX = buffer.create(4),
		WarpY = buffer.create(4),
		TintR = options.tintR or 1,
		TintG = options.tintG or 1,
		TintB = options.tintB or 1,
		TintAlpha = options.tintAlpha or 0,
		RedScale = 1,
		BlueScale = 1,
		BlurSigma = options.blurSigma or 0,
		FresnelIntensity = options.fresnelIntensity or 0,
		RimEnabled = options.rimEnabled or false,
		Row = options.outH,
		RowEnd = options.outH,
	}
end

return Helpers
