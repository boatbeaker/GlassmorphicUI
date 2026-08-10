--!strict
--!native
--!optimize 2

local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local AssetService = game:GetService("AssetService")

local EditableImageBlur, PixelColorApproximation
local Packages = script:FindFirstChild("Packages") or script.Parent
local EditableImageBlurModule = Packages:FindFirstChild("EditableImageBlur")
local PixelColorApproximationModule = Packages:FindFirstChild("PixelColorApproximation")

if
	EditableImageBlurModule
	and EditableImageBlurModule:IsA("ModuleScript")
	and PixelColorApproximationModule
	and PixelColorApproximationModule:IsA("ModuleScript")
then
	EditableImageBlur = require(EditableImageBlurModule)
	PixelColorApproximation = require(PixelColorApproximationModule)
end

if not EditableImageBlur or not PixelColorApproximation then
	error("Could not find required packages")
end

type GlassObject = {
	Window: ImageLabel,
	EditableImage: EditableImage?,
	WarnedImageCreateFailure: boolean,
	Pixels: buffer, -- u8 RGBA accumulator, row-major, unblurred
	Scratch: buffer, -- blur workspace, same length as Pixels
	PixelCount: number,
	PixelIndex: number, -- 0-based byte offset into Pixels
	InterlaceOffsetFlag: boolean,
	OpaqueFilled: boolean, -- the buffer already holds the opaque window color
	Resolution: Vector2,
	CellSizeX: number, -- window pixels per sample cell
	CellSizeY: number,
	CellCenterX: number, -- offset to a cell's center, in window pixels
	CellCenterY: number,
	WindowSizeX: number,
	WindowSizeY: number,
	WindowPositionX: number,
	WindowPositionY: number,
	WindowColor: { number },
	BlurRadius: number,
	Paused: boolean,
}

local function packColorU32(r: number, g: number, b: number): number
	-- Little-endian u32: R in the low byte, opaque alpha in the high byte
	return math.clamp(math.round(r * 255), 0, 255)
		+ math.clamp(math.round(g * 255), 0, 255) * 0x100
		+ math.clamp(math.round(b * 255), 0, 255) * 0x10000
		+ 0xFF000000
end

local GlassmorphicUI = {}

GlassmorphicUI._glassObjects = {} :: { GlassObject }
GlassmorphicUI._glassObjectUpdateIndex = 1
GlassmorphicUI._lastBlurDuration = 0
GlassmorphicUI._windowToObject = setmetatable({} :: { [ImageLabel]: GlassObject }, { __mode = "k" })

GlassmorphicUI.MAX_AXIS_SAMPLING_RES = 51
GlassmorphicUI.UPDATE_TIME_BUDGET = 3e-3
GlassmorphicUI.RADIUS = 5
GlassmorphicUI.TEMPORAL_SMOOTHING = 0.75
GlassmorphicUI.TAG_NAME = "GlassmorphicUI"
GlassmorphicUI.BLUR_RADIUS_ATTRIBUTE_NAME = "BlurRadius"

function GlassmorphicUI.new(): ImageLabel
	local Window = Instance.new("ImageLabel")
	-- Some reasonable defaults
	Window.Size = UDim2.fromScale(50, 30)
	Window.BackgroundColor3 = Color3.fromRGB(130, 215, 255)
	Window.BorderSizePixel = 0
	Window.BackgroundTransparency = 0.8
	Window.Name = "GlassmorphicUI"
	Window:AddTag(GlassmorphicUI.TAG_NAME)

	GlassmorphicUI._setupGlassWindow(Window)

	return Window
end

function GlassmorphicUI.setDefaultBlurRadius(radius: number)
	if type(radius) ~= "number" then
		return
	end
	GlassmorphicUI.RADIUS = math.clamp(math.round(radius), 1, GlassmorphicUI.MAX_AXIS_SAMPLING_RES / 2)
end

function GlassmorphicUI.applyGlassToImageLabel(ImageLabel: ImageLabel)
	if typeof(ImageLabel) == "Instance" and ImageLabel:IsA("ImageLabel") then
		ImageLabel:AddTag(GlassmorphicUI.TAG_NAME)
	end
end

function GlassmorphicUI.addGlassBackground(GuiObject: GuiObject): ImageLabel
	if typeof(GuiObject) ~= "Instance" or not GuiObject:IsA("GuiObject") then
		error("Expected GuiObject, got " .. typeof(GuiObject))
	end

	-- Ensure the glass isn't obstructed by the object
	GuiObject.BackgroundTransparency = 1
	GuiObject:GetPropertyChangedSignal("BackgroundTransparency"):Connect(function()
		GuiObject.BackgroundTransparency = 1
	end)

	local glassBackground = GlassmorphicUI.new()
	glassBackground.Size = UDim2.fromScale(1, 1)
	glassBackground.Position = UDim2.fromScale(0, 0)
	glassBackground.ZIndex = -999999
	glassBackground.Parent = GuiObject

	return glassBackground
end

function GlassmorphicUI.forceUpdate(Window: ImageLabel): ImageLabel
	local glassObject = GlassmorphicUI._windowToObject[Window]
	if glassObject then
		GlassmorphicUI._totalUpdate(glassObject)
	end
	return Window
end

function GlassmorphicUI.pauseUpdates(Window: ImageLabel): ImageLabel
	local glassObject = GlassmorphicUI._windowToObject[Window]
	if glassObject then
		glassObject.Paused = true
		local index = table.find(GlassmorphicUI._glassObjects, glassObject)
		if index then
			table.remove(GlassmorphicUI._glassObjects, index)
		end
	end
	return Window
end

function GlassmorphicUI.resumeUpdates(Window: ImageLabel): ImageLabel
	local glassObject = GlassmorphicUI._windowToObject[Window]
	if glassObject then
		glassObject.Paused = false
		if not table.find(GlassmorphicUI._glassObjects, glassObject) then
			table.insert(GlassmorphicUI._glassObjects, glassObject)
		end
	end
	return Window
end

function GlassmorphicUI._totalUpdate(glassObject: GlassObject)
	-- Perform a complete update
	local startPixel = glassObject.PixelIndex
	while true do
		local before = glassObject.PixelIndex
		GlassmorphicUI._processNextPixel(glassObject, true)
		local after = glassObject.PixelIndex
		-- Stop on wraparound, or when no progress was made (unparented window,
		-- opaque fast path, or a single-pixel image)
		if after == startPixel or after == before then
			break
		end
	end
	GlassmorphicUI._applyBlur(glassObject)
end

function GlassmorphicUI._ensureEditableImage(glassObject: GlassObject): EditableImage?
	local existing = glassObject.EditableImage
	if existing and existing.Size == glassObject.Resolution then
		return existing
	end

	local success, editableImage = pcall(AssetService.CreateEditableImage, AssetService, {
		Size = glassObject.Resolution,
	})
	if not success or not editableImage then
		-- Likely out of editable memory budget; retried on the next blur tick
		if not glassObject.WarnedImageCreateFailure then
			glassObject.WarnedImageCreateFailure = true
			warn(
				"GlassmorphicUI could not create an EditableImage:",
				if success then "budget exhausted" else editableImage
			)
		end
		return nil
	end
	glassObject.WarnedImageCreateFailure = false

	if existing then
		existing:Destroy()
	end
	glassObject.EditableImage = editableImage
	glassObject.Window.ImageContent = Content.fromObject(editableImage)
	editableImage:WritePixelsBuffer(Vector2.zero, glassObject.Resolution, glassObject.Pixels)

	return editableImage
end

function GlassmorphicUI._applyBlur(glassObject: GlassObject)
	local editableImage = GlassmorphicUI._ensureEditableImage(glassObject)
	if not editableImage then
		return
	end

	-- Blur a copy so the accumulator in Pixels stays unblurred.
	local scratch = glassObject.Scratch
	buffer.copy(scratch, 0, glassObject.Pixels)
	EditableImageBlur.Blur({
		pixelBuffer = scratch,
		width = glassObject.Resolution.X,
		height = glassObject.Resolution.Y,
		blurRadius = glassObject.BlurRadius,
		skipAlpha = true,
	})
	editableImage:WritePixelsBuffer(Vector2.zero, glassObject.Resolution, scratch)
end

function GlassmorphicUI._getGlassObject(Window: ImageLabel): GlassObject
	local glassObject = GlassmorphicUI._windowToObject[Window]
	if not glassObject then
		-- Start with a 1x1 window-color pixel, since _updateWindowSize copies
		-- old buffer contents into resized buffers
		local windowColor = Window.BackgroundColor3
		local initialPixels = buffer.create(4)
		buffer.writeu32(initialPixels, 0, packColorU32(windowColor.R, windowColor.G, windowColor.B))

		glassObject = {
			Window = Window,
			EditableImage = nil :: EditableImage?,
			WarnedImageCreateFailure = false,
			Pixels = initialPixels,
			Scratch = buffer.create(4),
			PixelCount = 1,
			PixelIndex = 0,
			InterlaceOffsetFlag = true,
			OpaqueFilled = false,
			Resolution = Vector2.one,
			CellSizeX = 1,
			CellSizeY = 1,
			CellCenterX = 0.5,
			CellCenterY = 0.5,
			WindowSizeX = 1,
			WindowSizeY = 1,
			WindowPositionX = 0,
			WindowPositionY = 0,
			WindowColor = {
				Window.BackgroundColor3.R,
				Window.BackgroundColor3.G,
				Window.BackgroundColor3.B,
				1 - Window.BackgroundTransparency,
			},
			BlurRadius = GlassmorphicUI.RADIUS,
			Paused = false,
		}
		GlassmorphicUI._windowToObject[Window] = glassObject
	end
	return glassObject
end

function GlassmorphicUI._setupGlassWindow(Window: ImageLabel)
	if GlassmorphicUI._windowToObject[Window] then
		-- This window is already set up
		return Window
	end

	local glassObject = GlassmorphicUI._getGlassObject(Window)
	GlassmorphicUI._watchProperties(glassObject)

	Window.Destroying:Connect(function()
		GlassmorphicUI._removeInstance(Window)
	end)

	GlassmorphicUI._onInitialParented(Window, function()
		GlassmorphicUI._updateWindowColor(glassObject)
		GlassmorphicUI._updateWindowPosition(glassObject)
		GlassmorphicUI._updateWindowSize(glassObject)
		GlassmorphicUI._updateWindowBlurRadius(glassObject)

		GlassmorphicUI._totalUpdate(glassObject)

		if not glassObject.Paused then
			table.insert(GlassmorphicUI._glassObjects, glassObject)
		end
	end)

	return Window
end

function GlassmorphicUI._onInitialParented(Object: GuiObject, callback: () -> nil)
	if Object:IsDescendantOf(game) then
		task.spawn(callback)
	else
		local initializeConnection
		initializeConnection = Object.AncestryChanged:Connect(function()
			if not Object:IsDescendantOf(game) then
				return
			end

			initializeConnection:Disconnect()

			-- Wait for window properties to load in engine
			if
				Object.Size.X.Offset == 0
				and Object.Size.Y.Offset == 0
				and Object.Size.X.Scale == 0
				and Object.Size.Y.Scale == 0
			then
				-- I don't know how to tell if it loaded since the expected size is actually 0
				task.wait()
			else
				local absoluteSize = Object.AbsoluteSize
				while task.wait() do
					if absoluteSize.X ~= 0 or absoluteSize.Y ~= 0 then
						break
					end
					absoluteSize = Object.AbsoluteSize
				end
			end

			callback()
		end)
	end
end

function GlassmorphicUI._watchProperties(glassObject: GlassObject)
	local Window = glassObject.Window

	Window:GetPropertyChangedSignal("AbsolutePosition"):Connect(function()
		GlassmorphicUI._updateWindowPosition(glassObject)
	end)
	Window:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		GlassmorphicUI._updateWindowSize(glassObject)
	end)
	Window:GetPropertyChangedSignal("BackgroundColor3"):Connect(function()
		GlassmorphicUI._updateWindowColor(glassObject)
	end)
	Window:GetPropertyChangedSignal("BackgroundTransparency"):Connect(function()
		GlassmorphicUI._updateWindowColor(glassObject)
	end)
	Window:GetAttributeChangedSignal(GlassmorphicUI.BLUR_RADIUS_ATTRIBUTE_NAME):Connect(function(radius)
		GlassmorphicUI._updateWindowBlurRadius(glassObject, radius)
	end)
end

function GlassmorphicUI._updateWindowBlurRadius(glassObject: GlassObject, radius: number?)
	if not radius then
		radius = glassObject.Window:GetAttribute(GlassmorphicUI.BLUR_RADIUS_ATTRIBUTE_NAME)
	end
	if type(radius) ~= "number" then
		return
	end
	glassObject.BlurRadius = math.clamp(math.round(radius), 1, GlassmorphicUI.MAX_AXIS_SAMPLING_RES / 2)
end

function GlassmorphicUI._updateWindowPosition(glassObject: GlassObject)
	local Window = glassObject.Window
	local absolutePosition = Window.AbsolutePosition
	glassObject.WindowPositionX = absolutePosition.X
	glassObject.WindowPositionY = absolutePosition.Y
end

function GlassmorphicUI._updateWindowColor(glassObject: GlassObject)
	local Window = glassObject.Window
	local windowAlpha = 1 - Window.BackgroundTransparency
	local windowColor = Window.BackgroundColor3
	glassObject.WindowColor[1] = windowColor.R
	glassObject.WindowColor[2] = windowColor.G
	glassObject.WindowColor[3] = windowColor.B
	glassObject.WindowColor[4] = windowAlpha
	glassObject.OpaqueFilled = false
end

function GlassmorphicUI._updateWindowSize(glassObject: GlassObject)
	local Window = glassObject.Window

	local absoluteSize = Window.AbsoluteSize
	local windowSizeX, windowSizeY = absoluteSize.X, absoluteSize.Y

	if windowSizeX == 0 or windowSizeY == 0 then
		return
	end

	glassObject.WindowSizeX = windowSizeX
	glassObject.WindowSizeY = windowSizeY

	local maxAxis = math.max(windowSizeX, windowSizeY)
	local samplerSize = maxAxis / math.min(GlassmorphicUI.MAX_AXIS_SAMPLING_RES, maxAxis)

	local resolutionX, resolutionY = windowSizeX // samplerSize, windowSizeY // samplerSize
	local resolution = Vector2.new(resolutionX, resolutionY)

	-- Sample cell geometry shifts whenever the window size does, even when
	-- the quantized resolution stays put
	local cellSizeX, cellSizeY = windowSizeX / resolutionX, windowSizeY / resolutionY
	glassObject.CellSizeX = cellSizeX
	glassObject.CellSizeY = cellSizeY
	glassObject.CellCenterX = cellSizeX / 2
	glassObject.CellCenterY = cellSizeY / 2

	if resolution == glassObject.Resolution and glassObject.EditableImage ~= nil then
		return
	end

	glassObject.Resolution = resolution
	glassObject.OpaqueFilled = false

	-- Reallocate the pixel buffers at the new resolution
	local WindowColor = glassObject.WindowColor
	local pixelCount = resolutionX * resolutionY
	local bufferLength = pixelCount * 4
	local oldPixels = glassObject.Pixels
	local Pixels = buffer.create(bufferLength)

	-- Fill with the window color, then keep whatever old data fits
	local windowColorU32 = packColorU32(WindowColor[1], WindowColor[2], WindowColor[3])
	for offset = 0, bufferLength - 4, 4 do
		buffer.writeu32(Pixels, offset, windowColorU32)
	end
	buffer.copy(Pixels, 0, oldPixels, 0, math.min(buffer.len(oldPixels), bufferLength))

	glassObject.Pixels = Pixels
	glassObject.Scratch = buffer.create(bufferLength)
	glassObject.PixelCount = pixelCount

	-- Move index back to start if new size is smaller
	if glassObject.PixelIndex >= bufferLength then
		glassObject.PixelIndex = if glassObject.InterlaceOffsetFlag or bufferLength <= 4 then 0 else 4
	end
end

function GlassmorphicUI._processNextPixel(glassObject: GlassObject, skipTween: boolean?): boolean
	local Window = glassObject.Window
	if (not Window) or not Window.Parent then
		return false
	end

	local Pixels, PixelIndex = glassObject.Pixels, glassObject.PixelIndex
	local bufferLength = glassObject.PixelCount * 4
	local WindowColor = glassObject.WindowColor

	if WindowColor[4] == 1 then
		-- Our window is not transparent, so there's no need to sample underneath
		-- (It's also not glassmorphic anymore, but that's not our problem)

		-- The buffer only needs one fill per color/size change; skip the
		-- refill (and the caller's blur) once it's done and displayed
		if glassObject.OpaqueFilled and glassObject.EditableImage then
			return false
		end

		-- Set entire image to window color
		local windowColorU32 = packColorU32(WindowColor[1], WindowColor[2], WindowColor[3])
		for offset = 0, bufferLength - 4, 4 do
			buffer.writeu32(Pixels, offset, windowColorU32)
		end
		glassObject.OpaqueFilled = true

		-- Move index back to start
		glassObject.PixelIndex = if glassObject.InterlaceOffsetFlag or bufferLength <= 4 then 0 else 4
		return true
	end

	local resolutionX = glassObject.Resolution.X

	-- Sample color at the center of our sample
	local indexFloor4 = PixelIndex // 4
	local color = PixelColorApproximation:GetColor(
		Vector2.new(
			glassObject.CellSizeX * (indexFloor4 % resolutionX) + glassObject.CellCenterX + glassObject.WindowPositionX,
			glassObject.CellSizeY * (indexFloor4 // resolutionX) + glassObject.CellCenterY + glassObject.WindowPositionY
		),
		Window
	)

	-- Blend window color on top
	local windowAlpha = WindowColor[4]
	color[1] = (1 - windowAlpha) * color[1] + windowAlpha * WindowColor[1]
	color[2] = (1 - windowAlpha) * color[2] + windowAlpha * WindowColor[2]
	color[3] = (1 - windowAlpha) * color[3] + windowAlpha * WindowColor[3]

	if skipTween then
		buffer.writeu8(Pixels, PixelIndex, math.clamp(math.round(color[1] * 255), 0, 255))
		buffer.writeu8(Pixels, PixelIndex + 1, math.clamp(math.round(color[2] * 255), 0, 255))
		buffer.writeu8(Pixels, PixelIndex + 2, math.clamp(math.round(color[3] * 255), 0, 255))
	else
		local smoothing = GlassmorphicUI.TEMPORAL_SMOOTHING
		local prevR = buffer.readu8(Pixels, PixelIndex)
		local prevG = buffer.readu8(Pixels, PixelIndex + 1)
		local prevB = buffer.readu8(Pixels, PixelIndex + 2)
		buffer.writeu8(Pixels, PixelIndex, math.clamp(math.round(prevR + (color[1] * 255 - prevR) * smoothing), 0, 255))
		buffer.writeu8(
			Pixels,
			PixelIndex + 1,
			math.clamp(math.round(prevG + (color[2] * 255 - prevG) * smoothing), 0, 255)
		)
		buffer.writeu8(
			Pixels,
			PixelIndex + 2,
			math.clamp(math.round(prevB + (color[3] * 255 - prevB) * smoothing), 0, 255)
		)
	end

	PixelIndex += 8
	if PixelIndex >= bufferLength then
		glassObject.InterlaceOffsetFlag = not glassObject.InterlaceOffsetFlag
		PixelIndex = if glassObject.InterlaceOffsetFlag or bufferLength <= 4 then 0 else 4
	end

	glassObject.PixelIndex = PixelIndex
	return true
end

function GlassmorphicUI._update()
	local totalGlassObjects = #GlassmorphicUI._glassObjects
	if totalGlassObjects == 0 then
		return
	end

	-- Reserve room for the blur pass using last tick's measured duration
	-- (roughly 1e-4s per max-size window when nothing is measured yet)
	local estimatedBlurTime = GlassmorphicUI._lastBlurDuration
	if estimatedBlurTime <= 0 then
		estimatedBlurTime = totalGlassObjects * 1e-4
	end
	local allottedPixelProcessingTime = math.max(GlassmorphicUI.UPDATE_TIME_BUDGET - estimatedBlurTime, 1e-3)

	local startClock = os.clock()

	-- Process pixels until time is up
	local updatedGlassObjects = {}
	while os.clock() - startClock < allottedPixelProcessingTime do
		local glassObject = GlassmorphicUI._glassObjects[GlassmorphicUI._glassObjectUpdateIndex]
		if glassObject and GlassmorphicUI._processNextPixel(glassObject, false) then
			updatedGlassObjects[GlassmorphicUI._glassObjectUpdateIndex] = glassObject
		end
		GlassmorphicUI._glassObjectUpdateIndex += 1

		if GlassmorphicUI._glassObjectUpdateIndex > totalGlassObjects then
			GlassmorphicUI._glassObjectUpdateIndex = 1
		end
	end

	-- Blur and apply the pixels for the updated objects
	local blurClock = os.clock()
	for _, glassObject in updatedGlassObjects do
		GlassmorphicUI._applyBlur(glassObject)
	end
	GlassmorphicUI._lastBlurDuration = os.clock() - blurClock
end

function GlassmorphicUI._addInstance(Instance: Instance)
	if Instance:IsA("ImageLabel") then
		GlassmorphicUI._setupGlassWindow(Instance)
	elseif Instance:IsA("GuiObject") then
		GlassmorphicUI.addGlassBackground(Instance)
	end
end

function GlassmorphicUI._removeInstance(Instance: Instance)
	if Instance:IsA("ImageLabel") then
		local glassObject = GlassmorphicUI._windowToObject[Instance]
		if glassObject then
			GlassmorphicUI._windowToObject[Instance] = nil

			local index = table.find(GlassmorphicUI._glassObjects, glassObject)
			if index then
				table.remove(GlassmorphicUI._glassObjects, index)
			end

			if glassObject.EditableImage then
				glassObject.EditableImage:Destroy()
			end
			-- Unbind the image; pcall covers windows that are already destroyed
			pcall(function()
				Instance.ImageContent = Content.none
			end)

			table.clear(glassObject)
			table.freeze(glassObject)
		end
	end
end

CollectionService:GetInstanceRemovedSignal(GlassmorphicUI.TAG_NAME):Connect(GlassmorphicUI._removeInstance)
CollectionService:GetInstanceAddedSignal(GlassmorphicUI.TAG_NAME):Connect(GlassmorphicUI._addInstance)
for _, Instance in CollectionService:GetTagged(GlassmorphicUI.TAG_NAME) do
	GlassmorphicUI._addInstance(Instance)
end

RunService.Heartbeat:Connect(function()
	GlassmorphicUI._update()
end)

return table.freeze({
	new = GlassmorphicUI.new,
	applyGlassToImageLabel = GlassmorphicUI.applyGlassToImageLabel,
	addGlassBackground = GlassmorphicUI.addGlassBackground,
	forceUpdate = GlassmorphicUI.forceUpdate,
	pauseUpdates = GlassmorphicUI.pauseUpdates,
	resumeUpdates = GlassmorphicUI.resumeUpdates,
	setDefaultBlurRadius = GlassmorphicUI.setDefaultBlurRadius,
})
