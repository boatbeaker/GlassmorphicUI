--!strict
--!native
--!optimize 2

-- Window outline: rounded rect with superellipse corners. Single implementation for all uses

local Types = require(script.Parent.Types)

type LiquidParams = Types.LiquidParams

local Shape = {}

-- Signed distance of rounded rect at (qx, qy); corner region uses superellipse arc
function Shape.sdfRoundedRect(qx: number, qy: number, radius: number, n: number, invN: number): number
	if qx > 0 and qy > 0 then
		return (qx ^ n + qy ^ n) ^ invN - radius
	end
	local ddx, ddy = qx - radius, qy - radius
	local mx = if ddx > 0 then ddx else 0
	local my = if ddy > 0 then ddy else 0
	local inner = if ddx > ddy then ddx else ddy
	return math.sqrt(mx * mx + my * my) + (if inner < 0 then inner else 0)
end

-- Shape constants shared by every stage that traces the outline: half
-- extents, corner radius clamped to fit, corner insets, and the
-- superellipse exponent with its inverse. One derivation keeps every
-- stage on the same shape.
function Shape.deriveShape(
	params: LiquidParams,
	winW: number,
	winH: number
): (number, number, number, number, number, number, number)
	local halfW, halfH = winW / 2, winH / 2
	local radius = math.min(params.cornerRadius, halfW, halfH)
	local n = params.superEllipseFactor
	return halfW, halfH, radius, halfW - radius, halfH - radius, n, 1 / n
end

return Shape
