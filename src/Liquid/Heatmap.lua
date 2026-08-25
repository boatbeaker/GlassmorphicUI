--!strict
--!native
--!optimize 2

-- Debug visualization: heatmap of sampler local density. Reads warp LUTs reconstruction uses

local Warp = require(script.Parent.Warp)
local Types = require(script.Parent.Types)

type ReconJob = Types.ReconJob

local warpLookup = Warp.warpLookup
local warpLookupX = Warp.warpLookupX
local WARP_LUT_MAX = Warp.WARP_LUT_MAX

-- Density heatmap: blue (sparse) to red (dense)
local HEAT_STOPS = {
	{ 20, 20, 120 }, -- deep blue: ~1/8x uniform and below
	{ 0, 150, 255 },
	{ 0, 220, 120 }, -- green: around uniform
	{ 255, 220, 0 },
	{ 255, 40, 0 }, -- red: ~32x uniform and above
}
local HEAT_LOG_MIN = -3
local HEAT_LOG_MAX = 5

local Heatmap = {}

-- The alpha mask is kept so the shape reads in context. Completes the
-- job synchronously.
function Heatmap.renderDensityHeatmap(job: ReconJob)
	local out, aux = job.Out, job.Aux
	local outW, outH = job.OutW, job.OutH
	local stepX, stepY = job.StepX, job.StepY
	local warpX, warpY = job.WarpX, job.WarpY
	local gridHm1 = job.GridH - 1
	local lutScaleX = WARP_LUT_MAX / (stepX * outW)
	local lutScaleY = WARP_LUT_MAX / (stepY * outH)
	local baseX = job.GridW / (stepX * outW) -- uniform grid cells per window px
	local baseY = job.GridH / (stepY * outH)
	local logRange = HEAT_LOG_MAX - HEAT_LOG_MIN
	local stopCount = #HEAT_STOPS

	-- Computes density ratios from the warp mapping's derivatives. The x
	-- ratio is per-pixel, because each row carries its own conditional x
	-- warp.
	for y = 1, outH do
		local wy = (y - 0.5) * stepY
		local gy = warpLookup(warpY, 0, wy * lutScaleY)
		local slopeY = (
			warpLookup(warpY, 0, (wy + 0.5 * stepY) * lutScaleY)
			- warpLookup(warpY, 0, (wy - 0.5 * stepY) * lutScaleY)
		) / stepY
		local ry = math.max(slopeY / baseY, 1e-4)
		local rowOffset = (y - 1) * outW * 4
		for x = 1, outW do
			local offset = rowOffset + (x - 1) * 4
			local alpha = buffer.readu8(aux, offset + 2)
			if alpha == 0 then
				buffer.writeu32(out, offset, 0)
			else
				local wx = (x - 0.5) * stepX
				local slopeX = (
					warpLookupX(warpX, gy, gridHm1, (wx + 0.5 * stepX) * lutScaleX)
					- warpLookupX(warpX, gy, gridHm1, (wx - 0.5 * stepX) * lutScaleX)
				) / stepX
				local rx = math.max(slopeX / baseX, 1e-4)
				local t = math.clamp((math.log(rx * ry, 2) - HEAT_LOG_MIN) / logRange, 0, 1)
				local scaled = t * (stopCount - 1)
				local i0 = math.min(scaled // 1, stopCount - 2)
				local fraction = scaled - i0
				local c0 = HEAT_STOPS[i0 + 1]
				local c1 = HEAT_STOPS[i0 + 2]
				local r = c0[1] + (c1[1] - c0[1]) * fraction
				local g = c0[2] + (c1[2] - c0[2]) * fraction
				local b = c0[3] + (c1[3] - c0[3]) * fraction
				buffer.writeu32(
					out,
					offset,
					(r + 0.5) // 1 + (g + 0.5) // 1 * 0x100 + (b + 0.5) // 1 * 0x10000 + alpha * 0x1000000
				)
			end
		end
	end

	job.Row = outH
end

return Heatmap
