--!strict
--!native
--!optimize 2

-- Stage E: blur output image. Runs in two quantization-aware steps because blur can only deliver discrete amounts

local Liquid = require(script.Parent.Liquid)
local Config = require(script.Parent.Config)

-- EditableImageBlur.Blur signature; injected to allow different imports (main thread vs worker)
export type BlurFunction = ({
	pixelBuffer: buffer,
	width: number,
	height: number,
	blurRadius: number,
}) -> ()

-- Variance for a given blur level; EditableImageBlur only delivers these discrete amounts
local function levelVariance(level: number): number
	return (level + 1) * (3 * level + 4) / 3
end

-- Inverts levelVariance: finds fractional level for exact variance
local function exactLevel(variance: number): number
	return (math.sqrt(1 + 36 * variance) - 7) / 6
end

-- Largest level with variance <= given amount; -1 if level 0 exceeds it
local function levelBelow(variance: number): number
	return math.floor(exactLevel(variance))
end

-- Smallest level whose variance is at least the given variance
local function levelAbove(variance: number): number
	return math.max(math.ceil(exactLevel(variance)), 0)
end

-- Sigma for a given level that quantizes exactly to that level
local function levelSigma(level: number): number
	return math.sqrt((2 * level + 2) ^ 2 - 1) / 2
end

local function ensureBuffer(existing: buffer?, length: number): buffer
	return if existing and buffer.len(existing) == length then existing else buffer.create(length)
end

local Frost = {}

-- Apply frost blur; reads from completed ReconJob so results agree with snapshot even if state changed. Reuse blendScratch buffer
function Frost.apply(job: Liquid.ReconJob, blur: BlurFunction, blendScratch: buffer?): buffer?
	local outPixels = job.Out
	local outW, outH = job.OutW, job.OutH
	local sigma = job.BlurSigma
	if sigma < Config.MIN_BLUR_SIGMA then
		return blendScratch
	end

	local length = buffer.len(outPixels)

	-- Premultiply color by coverage; blur averages covered color only. Prevents tint from bleeding as fake coverage
	local premultiplied = not Config.DEBUG_FROST_NO_PREMULTIPLY
	if premultiplied then
		debug.profilebegin("GlassFrostPremul")
		for i = 0, length - 4, 4 do
			local alpha = buffer.readu8(outPixels, i + 3)
			if alpha == 0 then
				buffer.writeu32(outPixels, i, 0)
			elseif alpha < 255 then
				local scale = alpha / 255
				buffer.writeu8(outPixels, i, (buffer.readu8(outPixels, i) * scale + 0.5) // 1)
				buffer.writeu8(outPixels, i + 1, (buffer.readu8(outPixels, i + 1) * scale + 0.5) // 1)
				buffer.writeu8(outPixels, i + 2, (buffer.readu8(outPixels, i + 2) * scale + 0.5) // 1)
			end
		end
		debug.profileend()
	end

	-- Two-step quantization-aware blur: base level at or below request, top level one above. Mix by residual to hit exact variance
	if Config.DEBUG_FROST_NEAREST_LEVEL then
		blur({
			pixelBuffer = outPixels,
			width = outW,
			height = outH,
			blurRadius = sigma,
		})
	else
		local variance = sigma * sigma
		local baseLevel = levelBelow(variance)
		local residual = variance
		if baseLevel >= 0 then
			residual -= levelVariance(baseLevel)
			blur({
				pixelBuffer = outPixels,
				width = outW,
				height = outH,
				blurRadius = levelSigma(baseLevel),
			})
		end
		if residual > 1e-3 then
			local topLevel = levelAbove(residual)
			local blendWeight = math.min(residual / levelVariance(topLevel), 1)
			local base = ensureBuffer(blendScratch, length)
			blendScratch = base
			buffer.copy(base, 0, outPixels)
			blur({
				pixelBuffer = outPixels,
				width = outW,
				height = outH,
				blurRadius = levelSigma(topLevel),
			})
			debug.profilebegin("GlassFrostMix")
			for i = 0, length - 1 do
				local baseByte = buffer.readu8(base, i)
				buffer.writeu8(
					outPixels,
					i,
					(baseByte + (buffer.readu8(outPixels, i) - baseByte) * blendWeight + 0.5) // 1
				)
			end
			debug.profileend()
		end
	end

	-- Divide blurred coverage back out, restore mask alpha to keep silhouette crisp
	local aux = job.Aux
	local clearColor = Liquid.clearColor(job.TintR, job.TintG, job.TintB)
	debug.profilebegin("GlassFrostNormalize")
	for i = 0, length - 4, 4 do
		local maskAlpha = buffer.readu8(aux, i + 2)
		if maskAlpha == 0 then
			buffer.writeu32(outPixels, i, clearColor)
		elseif premultiplied then
			local coverage = buffer.readu8(outPixels, i + 3)
			local scale = if coverage > 0 then 255 / coverage else 0
			for channel = i, i + 2 do
				buffer.writeu8(
					outPixels,
					channel,
					math.min((buffer.readu8(outPixels, channel) * scale + 0.5) // 1, 255)
				)
			end
			buffer.writeu8(outPixels, i + 3, maskAlpha)
		else
			buffer.writeu8(outPixels, i + 3, maskAlpha)
		end
	end
	debug.profileend()

	return blendScratch
end

return Frost
