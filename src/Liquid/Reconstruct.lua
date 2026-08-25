--!strict
--!native
--!optimize 2

-- Stages D and F: reconstruction and rim shading. Grid resample for resize warm-start

local Warp = require(script.Parent.Warp)
local Geometry = require(script.Parent.Geometry)
local Types = require(script.Parent.Types)

type ReconJob = Types.ReconJob

local warpLookup = Warp.warpLookup
local warpLookupX = Warp.warpLookupX
local WARP_LUT_MAX = Warp.WARP_LUT_MAX

local INV_DISP_FIXED_SCALE = 1 / Geometry.DISP_FIXED_SCALE
local INV_255 = 1 / 255

local band = bit32.band
local rshift = bit32.rshift

local Reconstruct = {}

-- Packed u32 for pixels outside mask: tint at zero alpha to reduce fringing
local function clearColor(tintR: number, tintG: number, tintB: number): number
	return (tintR * 255 + 0.5) // 1 + ((tintG * 255 + 0.5) // 1) * 0x100 + ((tintB * 255 + 0.5) // 1) * 0x10000
end
Reconstruct.clearColor = clearColor

-- Bilinearly resamples an RGBA u8 grid into a new resolution, to
-- warm-start temporal smoothing when the source grid remaps; otherwise a
-- resize would visibly reload through the smoothing.
function Reconstruct.resampleGridBilinear(
	old: buffer,
	oldW: number,
	oldH: number,
	new: buffer,
	newW: number,
	newH: number
)
	local oldWm1, oldHm1 = oldW - 1, oldH - 1
	local scaleX, scaleY = oldW / newW, oldH / newH
	for y = 0, newH - 1 do
		local sampleY = math.clamp((y + 0.5) * scaleY - 0.5, 0, oldHm1)
		local y0 = sampleY // 1
		local fy = sampleY - y0
		local y1 = if y0 < oldHm1 then y0 + 1 else y0
		local rowBase0 = y0 * oldW
		local rowBase1 = y1 * oldW
		local rowOffset = y * newW * 4
		for x = 0, newW - 1 do
			local sampleX = math.clamp((x + 0.5) * scaleX - 0.5, 0, oldWm1)
			local x0 = sampleX // 1
			local fx = sampleX - x0
			local x1 = if x0 < oldWm1 then x0 + 1 else x0

			local o00 = (rowBase0 + x0) * 4
			local o10 = (rowBase0 + x1) * 4
			local o01 = (rowBase1 + x0) * 4
			local o11 = (rowBase1 + x1) * 4
			local w11 = fx * fy
			local w10 = fx - w11
			local w01 = fy - w11
			local w00 = 1 - fx - fy + w11

			local offset = rowOffset + x * 4
			for channel = 0, 2 do
				local value = buffer.readu8(old, o00 + channel) * w00
					+ buffer.readu8(old, o10 + channel) * w10
					+ buffer.readu8(old, o01 + channel) * w01
					+ buffer.readu8(old, o11 + channel) * w11
				buffer.writeu8(new, offset + channel, math.round(value))
			end
			buffer.writeu8(new, offset + 3, 255)
		end
	end
end

--[[
	The grid fetch is Catmull-Rom bicubic, not bilinear. The output
	magnifies the grid several times over, and bilinear magnification
	exposes the cell lattice: its gradient breaks at every cell boundary,
	which reads as blockiness. Catmull-Rom passes through exactly the same
	cell values, so it adds no blur, but it is smooth across cell
	boundaries, so the lattice vanishes. Its negative lobes can overshoot
	the 0-255 range near strong edges, so fetched channels clamp before
	the tint mix.
]]

-- Catmull-Rom weights for the four taps around a coordinate with
-- fractional part t. They sum to one; the outer pair dips negative.
local function cubicWeights(t: number): (number, number, number, number)
	local t2 = t * t
	local t3 = t2 * t
	return 0.5 * (2 * t2 - t3 - t), 0.5 * (3 * t3 - 5 * t2 + 2), 0.5 * (4 * t2 - 3 * t3 + t), 0.5 * (t3 - t2)
end

-- The four tap offsets around a grid coordinate, as cell-index * 4 with
-- the border cells repeated, plus the fractional part. The warp LUTs
-- already clamp the coordinate into [0, limit].
local function cubicTaps(coordinate: number, limit: number): (number, number, number, number, number)
	local base = coordinate // 1
	local before = if base > 0 then base - 1 else 0
	local after = if base < limit then base + 1 else base
	local far = if after < limit then after + 1 else after
	return before * 4, base * 4, after * 4, far * 4, coordinate - base
end

-- One grid row's horizontal Catmull-Rom pass, all three color channels
-- from the same four texel reads.
local function cubicRowFetch(
	grid: buffer,
	rowBase: number,
	xm4: number,
	x04: number,
	x14: number,
	x24: number,
	w0: number,
	w1: number,
	w2: number,
	w3: number
): (number, number, number)
	local c0 = buffer.readu32(grid, rowBase + xm4)
	local c1 = buffer.readu32(grid, rowBase + x04)
	local c2 = buffer.readu32(grid, rowBase + x14)
	local c3 = buffer.readu32(grid, rowBase + x24)
	return band(c0, 0xFF) * w0 + band(c1, 0xFF) * w1 + band(c2, 0xFF) * w2 + band(c3, 0xFF) * w3,
		band(rshift(c0, 8), 0xFF) * w0 + band(rshift(c1, 8), 0xFF) * w1 + band(rshift(c2, 8), 0xFF) * w2 + band(
			rshift(c3, 8),
			0xFF
		) * w3,
		band(rshift(c0, 16), 0xFF) * w0 + band(rshift(c1, 16), 0xFF) * w1 + band(rshift(c2, 16), 0xFF) * w2 + band(
			rshift(c3, 16),
			0xFF
		) * w3
end

-- Single-channel clamped Catmull-Rom fetch, used by the dispersion path
-- where each channel reads through its own displacement.
local function cubicChannel(
	grid: buffer,
	gridW: number,
	gridWm1: number,
	gridHm1: number,
	gx: number,
	gy: number,
	shift: number
): number
	if gx < 0 then
		gx = 0
	elseif gx > gridWm1 then
		gx = gridWm1
	end
	if gy < 0 then
		gy = 0
	elseif gy > gridHm1 then
		gy = gridHm1
	end
	local xm4, x04, x14, x24, tx = cubicTaps(gx, gridWm1)
	local ym4, y04, y14, y24, ty = cubicTaps(gy, gridHm1)
	local wx0, wx1, wx2, wx3 = cubicWeights(tx)
	local wy0, wy1, wy2, wy3 = cubicWeights(ty)
	local rb0, rb1, rb2, rb3 = ym4 * gridW, y04 * gridW, y14 * gridW, y24 * gridW
	local row0 = band(rshift(buffer.readu32(grid, rb0 + xm4), shift), 0xFF) * wx0
		+ band(rshift(buffer.readu32(grid, rb0 + x04), shift), 0xFF) * wx1
		+ band(rshift(buffer.readu32(grid, rb0 + x14), shift), 0xFF) * wx2
		+ band(rshift(buffer.readu32(grid, rb0 + x24), shift), 0xFF) * wx3
	local row1 = band(rshift(buffer.readu32(grid, rb1 + xm4), shift), 0xFF) * wx0
		+ band(rshift(buffer.readu32(grid, rb1 + x04), shift), 0xFF) * wx1
		+ band(rshift(buffer.readu32(grid, rb1 + x14), shift), 0xFF) * wx2
		+ band(rshift(buffer.readu32(grid, rb1 + x24), shift), 0xFF) * wx3
	local row2 = band(rshift(buffer.readu32(grid, rb2 + xm4), shift), 0xFF) * wx0
		+ band(rshift(buffer.readu32(grid, rb2 + x04), shift), 0xFF) * wx1
		+ band(rshift(buffer.readu32(grid, rb2 + x14), shift), 0xFF) * wx2
		+ band(rshift(buffer.readu32(grid, rb2 + x24), shift), 0xFF) * wx3
	local row3 = band(rshift(buffer.readu32(grid, rb3 + xm4), shift), 0xFF) * wx0
		+ band(rshift(buffer.readu32(grid, rb3 + x04), shift), 0xFF) * wx1
		+ band(rshift(buffer.readu32(grid, rb3 + x14), shift), 0xFF) * wx2
		+ band(rshift(buffer.readu32(grid, rb3 + x24), shift), 0xFF) * wx3
	return row0 * wy0 + row1 * wy1 + row2 * wy2 + row3 * wy3
end

-- Rebuilds output rows through the displacement map and the density
-- warp, compositing the tint and the alpha mask. Fresnel and glare
-- composite later (compositeRim), so the frost between the two can blur
-- the backdrop without softening the rim. Advances from job.Row until
-- job.RowEnd or the os.clock() deadline; returns true when the range
-- completes. Row math is absolute, so a worker reconstructing only its
-- band fetches through the same warp coordinates as a full pass.
function Reconstruct.reconstructRows(job: ReconJob, deadline: number): boolean
	local out, disp, aux, grid = job.Out, job.Disp, job.Aux, job.Grid
	local gridW = job.GridW
	local gridWm1, gridHm1 = job.GridW - 1, job.GridH - 1
	local outW, outH = job.OutW, job.OutH
	local rowEnd = job.RowEnd
	local stepX, stepY = job.StepX, job.StepY
	local warpX, warpY = job.WarpX, job.WarpY
	local lutScaleX = WARP_LUT_MAX / (stepX * outW)
	local lutScaleY = WARP_LUT_MAX / (stepY * outH)
	local tintAlpha = job.TintAlpha
	local keep = 1 - tintAlpha
	local tintR = job.TintR * 255 * tintAlpha
	local tintG = job.TintG * 255 * tintAlpha
	local tintB = job.TintB * 255 * tintAlpha
	local redScale, blueScale = job.RedScale, job.BlueScale
	local dispersing = redScale ~= 1
	local bilinear = job.BilinearFetch == true
	local clear = clearColor(job.TintR, job.TintG, job.TintB)

	-- Opaque short-circuit: at full tint alpha no backdrop can show
	-- through, so every pixel is the tint color under the mask alpha,
	-- with no grid reads at all.
	if job.TintAlpha >= 1 then
		local row = job.Row
		while row < rowEnd do
			local rowOffset = row * outW * 4
			for x = 0, outW - 1 do
				local offset = rowOffset + x * 4
				buffer.writeu32(out, offset, clear + buffer.readu8(aux, offset + 2) * 0x1000000)
			end
			row += 1
			if os.clock() >= deadline then
				break
			end
		end
		job.Row = row
		return row >= rowEnd
	end

	local row = job.Row
	while row < rowEnd do
		local wy = (row + 0.5) * stepY
		-- Interior pixels have exact-zero displacement, so their y lookup is
		-- row-constant; the fused path reuses this instead of re-lerping the LUT
		local rowGY = warpLookup(warpY, 0, wy * lutScaleY)
		local rowOffset = row * outW * 4
		for x = 0, outW - 1 do
			local offset = rowOffset + x * 4
			local alpha = buffer.readu8(aux, offset + 2)
			if alpha == 0 then
				buffer.writeu32(out, offset, clear) -- outside the shape
			else
				local dispX = buffer.readi16(disp, offset) * INV_DISP_FIXED_SCALE
				local dispY = buffer.readi16(disp, offset + 2) * INV_DISP_FIXED_SCALE
				local r: number, g: number, b: number
				if dispersing and (dispX ~= 0 or dispY ~= 0) then
					-- Per-channel path: displaced pixels whose channels can
					-- separate. Red gets the longest displacement
					-- and blue the shortest.
					local wx = (x + 0.5) * stepX
					local redY, greenY, blueY
					if dispY == 0 then
						-- Purely horizontal displacement: all three channel
						-- rows are the row-constant lookup
						redY, greenY, blueY = rowGY, rowGY, rowGY
					else
						redY = warpLookup(warpY, 0, (wy + dispY * redScale) * lutScaleY)
						greenY = warpLookup(warpY, 0, (wy + dispY) * lutScaleY)
						blueY = warpLookup(warpY, 0, (wy + dispY * blueScale) * lutScaleY)
					end
					local redX = warpLookupX(warpX, redY, gridHm1, (wx + dispX * redScale) * lutScaleX)
					local greenX = warpLookupX(warpX, greenY, gridHm1, (wx + dispX) * lutScaleX)
					local blueX = warpLookupX(warpX, blueY, gridHm1, (wx + dispX * blueScale) * lutScaleX)
					r = cubicChannel(grid, gridW, gridWm1, gridHm1, redX, redY, 0)
					g = cubicChannel(grid, gridW, gridWm1, gridHm1, greenX, greenY, 8)
					b = cubicChannel(grid, gridW, gridWm1, gridHm1, blueX, blueY, 16)
				else
					-- Fused path: dispersion is off or displacement is
					-- exactly zero, so the channels cannot separate and
					-- share one fetch's texel reads and weights. This
					-- covers most pixels. Looks up pixel center plus
					-- displacement through the density warp, row first
					-- because the x warp is conditional on the row.
					local gy = if dispY == 0 then rowGY else warpLookup(warpY, 0, (wy + dispY) * lutScaleY)
					local gx = warpLookupX(warpX, gy, gridHm1, ((x + 0.5) * stepX + dispX) * lutScaleX)
					if bilinear then
						-- Debug: the bilinear fetch Catmull-Rom replaced. Its
						-- gradient breaks at every cell boundary, which reads
						-- as blockiness once the output magnifies the grid.
						local x0 = gx // 1
						local fx = gx - x0
						local x1 = if x0 < gridWm1 then x0 + 1 else x0
						local y0 = gy // 1
						local fy = gy - y0
						local y1 = if y0 < gridHm1 then y0 + 1 else y0
						local c00 = buffer.readu32(grid, (y0 * gridW + x0) * 4)
						local c10 = buffer.readu32(grid, (y0 * gridW + x1) * 4)
						local c01 = buffer.readu32(grid, (y1 * gridW + x0) * 4)
						local c11 = buffer.readu32(grid, (y1 * gridW + x1) * 4)
						local w11 = fx * fy
						local w10 = fx - w11
						local w01 = fy - w11
						local w00 = 1 - fx - fy + w11
						r = band(c00, 0xFF) * w00
							+ band(c10, 0xFF) * w10
							+ band(c01, 0xFF) * w01
							+ band(c11, 0xFF) * w11
						g = band(rshift(c00, 8), 0xFF) * w00
							+ band(rshift(c10, 8), 0xFF) * w10
							+ band(rshift(c01, 8), 0xFF) * w01
							+ band(rshift(c11, 8), 0xFF) * w11
						b = band(rshift(c00, 16), 0xFF) * w00
							+ band(rshift(c10, 16), 0xFF) * w10
							+ band(rshift(c01, 16), 0xFF) * w01
							+ band(rshift(c11, 16), 0xFF) * w11
					else
						local xm4, x04, x14, x24, tx = cubicTaps(gx, gridWm1)
						local ym4, y04, y14, y24, ty = cubicTaps(gy, gridHm1)
						local wx0, wx1, wx2, wx3 = cubicWeights(tx)
						local wy0, wy1, wy2, wy3 = cubicWeights(ty)
						local r0, g0, b0 = cubicRowFetch(grid, ym4 * gridW, xm4, x04, x14, x24, wx0, wx1, wx2, wx3)
						local r1, g1, b1 = cubicRowFetch(grid, y04 * gridW, xm4, x04, x14, x24, wx0, wx1, wx2, wx3)
						local r2, g2, b2 = cubicRowFetch(grid, y14 * gridW, xm4, x04, x14, x24, wx0, wx1, wx2, wx3)
						local r3, g3, b3 = cubicRowFetch(grid, y24 * gridW, xm4, x04, x14, x24, wx0, wx1, wx2, wx3)
						r = r0 * wy0 + r1 * wy1 + r2 * wy2 + r3 * wy3
						g = g0 * wy0 + g1 * wy1 + g2 * wy2 + g3 * wy3
						b = b0 * wy0 + b1 * wy1 + b2 * wy2 + b3 * wy3
					end
				end
				-- The cubic's negative lobes can overshoot near strong
				-- edges, so clamp before the tint mix
				if r < 0 then
					r = 0
				elseif r > 255 then
					r = 255
				end
				if g < 0 then
					g = 0
				elseif g > 255 then
					g = 255
				end
				if b < 0 then
					b = 0
				elseif b > 255 then
					b = 255
				end
				r = r * keep + tintR
				g = g * keep + tintG
				b = b * keep + tintB
				buffer.writeu32(
					out,
					offset,
					(r + 0.5) // 1 + (g + 0.5) // 1 * 0x100 + (b + 0.5) // 1 * 0x10000 + alpha * 0x1000000
				)
			end
		end
		row += 1
		if os.clock() >= deadline then
			break
		end
	end

	job.Row = row
	return row >= rowEnd
end

-- Stage F: rim shading. Mixes each covered output pixel toward white by
-- the fresnel and glare factors baked in Stage A. Runs after the frost, so the rim
-- stays sharp over the blurred backdrop. The fresnel mix weight applies here;
-- the glare byte is fully baked. Both terms mix toward white, so they fold into one weight:
-- 1 - (1 - wf)(1 - wg).
function Reconstruct.compositeRim(out: buffer, aux: buffer, pixelCount: number, fresnelIntensity: number)
	local fresnelScale = fresnelIntensity * 0.7 * INV_255
	for offset = 0, pixelCount * 4 - 4, 4 do
		if buffer.readu8(aux, offset + 2) ~= 0 then
			local wf = buffer.readu8(aux, offset) * fresnelScale
			local wg = buffer.readu8(aux, offset + 1) * INV_255
			local white = wf + wg - wf * wg
			if white > 0 then
				local r = buffer.readu8(out, offset)
				local g = buffer.readu8(out, offset + 1)
				local b = buffer.readu8(out, offset + 2)
				buffer.writeu8(out, offset, (r + (255 - r) * white + 0.5) // 1)
				buffer.writeu8(out, offset + 1, (g + (255 - g) * white + 0.5) // 1)
				buffer.writeu8(out, offset + 2, (b + (255 - b) * white + 0.5) // 1)
			end
		end
	end
end

return Reconstruct
