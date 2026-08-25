--!strict
--!native
--!optimize 2

-- Reads window attributes and normalizes them to LiquidParams: percents to 0-1, degrees to radians, UDims resolved against min axis

local Liquid = require(script.Parent.Liquid)
local Config = require(script.Parent.Config)
local GlassObject = require(script.Parent.GlassObject)

type GlassObject = GlassObject.GlassObject

local function getNumberAttribute(Window: Instance, name: string): number?
	local value = Window:GetAttribute(name)
	return if type(value) == "number" then value else nil
end

local function clampedAttribute(Window: Instance, name: string, default: number, min: number, max: number): number
	return math.clamp(getNumberAttribute(Window, name) or default, min, max)
end

-- Length attributes are UDims on the UICorner convention: resolved px =
-- offset + scale * the window's min axis. Other types (including plain
-- numbers) fall back to the default, so the surface stays one type.
local function getUDimAttribute(Window: Instance, name: string): UDim?
	local value = Window:GetAttribute(name)
	return if typeof(value) == "UDim" then value else nil
end

local function resolveUDim(value: UDim, minAxis: number): number
	return value.Offset + value.Scale * minAxis
end

local Attributes = {}

Attributes.getNumberAttribute = getNumberAttribute

function Attributes.parseLiquidParams(glassObject: GlassObject, winW: number, winH: number): Liquid.LiquidParams
	local Window = glassObject.Window
	local minAxis = math.min(winW, winH)
	local halfMinAxis = minAxis / 2

	local function lengthAttribute(name: string, default: UDim, min: number, max: number): number
		return math.clamp(resolveUDim(getUDimAttribute(Window, name) or default, minAxis), min, max)
	end

	-- Percents are 0-100; normalize to 0-1
	local function percentAttribute(name: string, default: number, max: number): number
		return clampedAttribute(Window, name, default, 0, max) / 100
	end

	local cornerRadius: number?
	local cornerAttribute = getUDimAttribute(Window, "CornerRadius")
	if cornerAttribute then
		cornerRadius = resolveUDim(cornerAttribute, minAxis)
	else
		-- Auto mode: use UICorner child if present
		local uiCorner = Window:FindFirstChildWhichIsA("UICorner")
		if uiCorner then
			cornerRadius = resolveUDim(uiCorner.CornerRadius, minAxis)
		end
	end
	local resolvedCornerRadius = cornerRadius or resolveUDim(Config.DEFAULT_CORNER_RADIUS, minAxis)

	-- Length attributes clamp in resolved px, capped at min axis to handle scales exceeding slider ranges
	return {
		cornerRadius = math.clamp(resolvedCornerRadius, 0, halfMinAxis),
		superEllipseFactor = clampedAttribute(Window, "SuperEllipseFactor", Config.DEFAULT_SUPER_ELLIPSE_FACTOR, 2, 7),
		thickness = lengthAttribute("Thickness", Config.DEFAULT_THICKNESS, 1, minAxis),
		refractionFactor = clampedAttribute(Window, "RefractionFactor", Config.DEFAULT_REFRACTION_FACTOR, 1, 4),
		chromaticAberration = clampedAttribute(
			Window,
			"ChromaticAberration",
			Config.DEFAULT_CHROMATIC_ABERRATION,
			0,
			1
		),
		fresnelSize = lengthAttribute("FresnelSize", Config.DEFAULT_FRESNEL_SIZE, 0, minAxis),
		fresnelHardness = percentAttribute("FresnelHardness", Config.DEFAULT_FRESNEL_HARDNESS, 100),
		fresnelIntensity = percentAttribute("FresnelIntensity", Config.DEFAULT_FRESNEL_INTENSITY, 100),
		glareSize = lengthAttribute("GlareSize", Config.DEFAULT_GLARE_SIZE, 0, minAxis),
		glareHardness = percentAttribute("GlareHardness", Config.DEFAULT_GLARE_HARDNESS, 100),
		glareIntensity = percentAttribute("GlareIntensity", Config.DEFAULT_GLARE_INTENSITY, 120),
		glareConvergence = percentAttribute("GlareConvergence", Config.DEFAULT_GLARE_CONVERGENCE, 100),
		glareOppositeSide = percentAttribute("GlareOppositeSide", Config.DEFAULT_GLARE_OPPOSITE_SIDE, 100),
		glareAngle = math.rad(
			math.clamp(getNumberAttribute(Window, "GlareAngle") or Config.DEFAULT_GLARE_ANGLE, -180, 180)
		),
		maxOutputResolution = math.round(
			clampedAttribute(Window, "MaxOutputResolution", Config.DEFAULT_MAX_OUTPUT_RESOLUTION, 16, 1024)
		),
	}
end

function Attributes.updateWindowBlur(glassObject: GlassObject)
	local Window = glassObject.Window
	local radius = getUDimAttribute(Window, Config.BLUR_RADIUS_ATTRIBUTE_NAME) or Config.DEFAULT_BLUR_RADIUS
	local absoluteSize = Window.AbsoluteSize
	local minAxis = math.min(absoluteSize.X, absoluteSize.Y)
	glassObject.BlurRadius = math.clamp(resolveUDim(radius, minAxis), 1, math.max(minAxis, 1))
	glassObject.ForceRecon = true
end

return Attributes
