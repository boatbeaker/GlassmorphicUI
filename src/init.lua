--!strict

-- Renders Apple-style liquid glass into an EditableImage on CPU. See module structure in ARCHITECTURE.md

local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")

local Config = require(script.Config)
local GlassObject = require(script.GlassObject)
local Scheduler = require(script.Scheduler)
local Window = require(script.Window)

local GlassmorphicUI = {}

export type DebugStats = {
	GridResolution: Vector2, -- source-grid cells per axis
	OutputResolution: Vector2, -- output image px per axis
	SamplesLastFrame: number, -- backdrop samples this window got last frame
	GridWritesSinceRecon: number, -- grid cells actually changed since the last pass started
	FramesSinceRecon: number,
	ReconRoute: "parallel" | "sync" | "idle", -- what the current reconstruction pass runs on
}

function GlassmorphicUI.new(): Frame
	local window = Instance.new("Frame")
	window.Size = UDim2.fromOffset(200, 200)
	window.BackgroundColor3 = Color3.fromRGB(200, 220, 245)
	window.BorderSizePixel = 0
	window.BackgroundTransparency = 1
	window.Name = "GlassmorphicUI"
	window:AddTag(Config.TAG_NAME)

	Window.setup(window)

	return window
end

function GlassmorphicUI.setDefaultBlurRadius(radius: UDim)
	if typeof(radius) ~= "UDim" then
		return
	end
	Config.DEFAULT_BLUR_RADIUS = radius
end

function GlassmorphicUI.applyGlassToImageLabel(ImageLabel: ImageLabel)
	-- Backwards compat: silent guard matches 1.x contract
	if typeof(ImageLabel) == "Instance" and ImageLabel:IsA("GuiObject") then
		GlassmorphicUI.addGlassBackground(ImageLabel)
	end
end

function GlassmorphicUI.addGlassBackground(GuiObject: GuiObject): GuiObject
	if typeof(GuiObject) ~= "Instance" or not GuiObject:IsA("GuiObject") then
		error("Expected GuiObject, got " .. typeof(GuiObject))
	end
	GuiObject:AddTag(Config.TAG_NAME)
	return GuiObject
end

function GlassmorphicUI.forceUpdate(window: GuiObject): GuiObject
	local glassObject = GlassObject.byWindow[window]
	if glassObject then
		Scheduler.totalUpdate(glassObject)
	end
	return window
end

-- Returns live pipeline stats for one window; nil if no glass record
function GlassmorphicUI.getDebugStats(window: GuiObject): DebugStats?
	local glassObject = GlassObject.byWindow[window]
	if not glassObject then
		return nil
	end
	return {
		GridResolution = glassObject.Resolution,
		OutputResolution = glassObject.OutputResolution,
		SamplesLastFrame = glassObject.SamplesLastFrame,
		GridWritesSinceRecon = glassObject.GridWritesSinceRecon,
		FramesSinceRecon = glassObject.FramesSinceRecon,
		ReconRoute = if glassObject.ParallelJob then "parallel" elseif glassObject.ReconJob then "sync" else "idle",
	} :: DebugStats
end

function GlassmorphicUI.pauseUpdates(window: GuiObject): GuiObject
	local glassObject = GlassObject.byWindow[window]
	if glassObject then
		glassObject.Paused = true
		GlassObject.removeFromUpdateList(glassObject)
	end
	return window
end

function GlassmorphicUI.resumeUpdates(window: GuiObject): GuiObject
	local glassObject = GlassObject.byWindow[window]
	if glassObject then
		glassObject.Paused = false
		GlassObject.addToUpdateList(glassObject)
	end
	return window
end

CollectionService:GetInstanceRemovedSignal(Config.TAG_NAME):Connect(Window.removeInstance)
CollectionService:GetInstanceAddedSignal(Config.TAG_NAME):Connect(Window.addInstance)
for _, tagged in CollectionService:GetTagged(Config.TAG_NAME) do
	Window.addInstance(tagged)
end

RunService.Heartbeat:Connect(function()
	Scheduler.update()
end)

-- Built-in defaults exported for tooling; setDefaultBlurRadius overrides blur for new windows only
GlassmorphicUI.DEFAULT_CORNER_RADIUS = Config.DEFAULT_CORNER_RADIUS
GlassmorphicUI.DEFAULT_SUPER_ELLIPSE_FACTOR = Config.DEFAULT_SUPER_ELLIPSE_FACTOR
GlassmorphicUI.DEFAULT_THICKNESS = Config.DEFAULT_THICKNESS
GlassmorphicUI.DEFAULT_REFRACTION_FACTOR = Config.DEFAULT_REFRACTION_FACTOR
GlassmorphicUI.DEFAULT_CHROMATIC_ABERRATION = Config.DEFAULT_CHROMATIC_ABERRATION
GlassmorphicUI.DEFAULT_FRESNEL_SIZE = Config.DEFAULT_FRESNEL_SIZE
GlassmorphicUI.DEFAULT_FRESNEL_HARDNESS = Config.DEFAULT_FRESNEL_HARDNESS
GlassmorphicUI.DEFAULT_FRESNEL_INTENSITY = Config.DEFAULT_FRESNEL_INTENSITY
GlassmorphicUI.DEFAULT_GLARE_SIZE = Config.DEFAULT_GLARE_SIZE
GlassmorphicUI.DEFAULT_GLARE_HARDNESS = Config.DEFAULT_GLARE_HARDNESS
GlassmorphicUI.DEFAULT_GLARE_INTENSITY = Config.DEFAULT_GLARE_INTENSITY
GlassmorphicUI.DEFAULT_GLARE_CONVERGENCE = Config.DEFAULT_GLARE_CONVERGENCE
GlassmorphicUI.DEFAULT_GLARE_OPPOSITE_SIDE = Config.DEFAULT_GLARE_OPPOSITE_SIDE
GlassmorphicUI.DEFAULT_GLARE_ANGLE = Config.DEFAULT_GLARE_ANGLE
GlassmorphicUI.DEFAULT_BLUR_RADIUS = Config.DEFAULT_BLUR_RADIUS
GlassmorphicUI.DEFAULT_MAX_OUTPUT_RESOLUTION = Config.DEFAULT_MAX_OUTPUT_RESOLUTION

return table.freeze(GlassmorphicUI)
