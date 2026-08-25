--!strict
--!native
--!optimize 2

-- Window lifecycle: setup, watchers, teardown

local Liquid = require(script.Parent.Liquid)
local Config = require(script.Parent.Config)
local GlassObject = require(script.Parent.GlassObject)
local Attributes = require(script.Parent.Attributes)
local Layout = require(script.Parent.Layout)
local Scheduler = require(script.Parent.Scheduler)
local Parallel = require(script.Parent.Parallel)

type GlassObject = GlassObject.GlassObject

local Window = {}

-- Initial setup: seed tint, hand rendering to pane, hide window background
local function initializeWindow(glassObject: GlassObject)
	local window = glassObject.Window
	if not window or glassObject.Initialized then
		return
	end
	glassObject.Initialized = true

	if window:GetAttribute(Config.TRANSPARENCY_ATTRIBUTE_NAME) == nil then
		window:SetAttribute(Config.TRANSPARENCY_ATTRIBUTE_NAME, window.BackgroundTransparency)
	end
	window.BackgroundTransparency = 1
	Window.bindUICorner(glassObject)
end

local function onInitialParented(Object: GuiObject, callback: () -> nil)
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
				-- The expected size is 0 too, so there's no reliable way to detect load yet
				task.wait()
			else
				-- Destruction must end the polling: AbsoluteSize reads on a
				-- destroyed window keep returning zero silently, so the loop
				-- would otherwise never exit
				local destroyed = false
				local destroyingConnection = Object.Destroying:Connect(function()
					destroyed = true
				end)
				local absoluteSize = Object.AbsoluteSize
				while task.wait() do
					if destroyed then
						return
					end
					if absoluteSize.X ~= 0 or absoluteSize.Y ~= 0 then
						break
					end
					absoluteSize = Object.AbsoluteSize
				end
				destroyingConnection:Disconnect()
			end

			callback()
		end)
	end
end

local function updateWindowPosition(glassObject: GlassObject)
	local window = glassObject.Window
	local absolutePosition = window.AbsolutePosition
	glassObject.WindowPositionX = absolutePosition.X
	glassObject.WindowPositionY = absolutePosition.Y
end

local function updateWindowColor(glassObject: GlassObject)
	local window = glassObject.Window
	if not window then
		return
	end
	local tintTransparency = Attributes.getNumberAttribute(window, Config.TRANSPARENCY_ATTRIBUTE_NAME)
		or 1 - glassObject.WindowColor[4]
	local windowColor = window.BackgroundColor3
	glassObject.WindowColor[1] = windowColor.R
	glassObject.WindowColor[2] = windowColor.G
	glassObject.WindowColor[3] = windowColor.B
	glassObject.WindowColor[4] = 1 - math.clamp(tintTransparency, 0, 1)
	glassObject.ForceRecon = true
end

local function updateWindowSize(glassObject: GlassObject)
	local absoluteSize = glassObject.Window.AbsoluteSize
	if absoluteSize.X == 0 or absoluteSize.Y == 0 then
		return
	end
	Layout.request(glassObject)
end

-- Mirrors a UICorner child's CornerRadius into the glass shape when no
-- CornerRadius attribute overrides it
function Window.bindUICorner(glassObject: GlassObject)
	if glassObject.UICornerConnection then
		glassObject.UICornerConnection:Disconnect()
		glassObject.UICornerConnection = nil
	end
	local window = glassObject.Window
	if not window then
		return
	end
	local uiCorner = window:FindFirstChildWhichIsA("UICorner")
	if uiCorner then
		glassObject.UICornerConnection = uiCorner:GetPropertyChangedSignal("CornerRadius"):Connect(function()
			Layout.request(glassObject)
		end)
	end
end

local function watchProperties(glassObject: GlassObject)
	local window = glassObject.Window
	-- Every connection is tracked so removeInstance can disconnect them.
	-- An untagged window stays alive, and a handler firing after removal
	-- would index the cleared, frozen glassObject.
	local connections = glassObject.Connections

	table.insert(
		connections,
		window.AncestryChanged:Connect(function()
			-- The sampler reads this flag per pixel instead of Window.Parent
			glassObject.Parented = window.Parent ~= nil
		end)
	)
	table.insert(
		connections,
		window:GetPropertyChangedSignal("AbsolutePosition"):Connect(function()
			updateWindowPosition(glassObject)
		end)
	)
	table.insert(
		connections,
		window:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
			updateWindowSize(glassObject)
		end)
	)
	table.insert(
		connections,
		window:GetPropertyChangedSignal("BackgroundColor3"):Connect(function()
			updateWindowColor(glassObject)
		end)
	)
	table.insert(
		connections,
		window:GetPropertyChangedSignal("BackgroundTransparency"):Connect(function()
			-- The output image's alpha mask carries the rounded shape, so the
			-- label's own square background must stay invisible. Tint alpha
			-- is stored in the Transparency attribute instead.
			if glassObject.Initialized and window.BackgroundTransparency ~= 1 then
				window.BackgroundTransparency = 1
			end
		end)
	)
	table.insert(
		connections,
		window:GetAttributeChangedSignal(Config.BLUR_RADIUS_ATTRIBUTE_NAME):Connect(function()
			Attributes.updateWindowBlur(glassObject)
		end)
	)
	table.insert(
		connections,
		window:GetAttributeChangedSignal(Config.TRANSPARENCY_ATTRIBUTE_NAME):Connect(function()
			updateWindowColor(glassObject)
		end)
	)
	for _, attributeName in Config.LIQUID_PARAM_ATTRIBUTES do
		table.insert(
			connections,
			window:GetAttributeChangedSignal(attributeName):Connect(function()
				if attributeName == "MaxOutputResolution" then
					glassObject.LadderCap = math.huge
				end
				if glassObject.Initialized then
					Layout.request(glassObject)
				end
			end)
		)
	end
	local function onChildChanged(child: Instance)
		if child:IsA("UICorner") and glassObject.Initialized then
			Window.bindUICorner(glassObject)
			Layout.request(glassObject)
		end
	end
	table.insert(connections, window.ChildAdded:Connect(onChildChanged))
	table.insert(connections, window.ChildRemoved:Connect(onChildChanged))
end

function Window.setup(guiObject: GuiObject)
	if GlassObject.byWindow[guiObject] then
		-- This window is already set up
		return guiObject
	end

	local glassObject = GlassObject.create(guiObject)
	watchProperties(glassObject)

	table.insert(
		glassObject.Connections,
		guiObject.Destroying:Connect(function()
			Window.removeInstance(guiObject)
		end)
	)

	onInitialParented(guiObject, function()
		initializeWindow(glassObject)
		updateWindowColor(glassObject)
		updateWindowPosition(glassObject)
		updateWindowSize(glassObject)
		Attributes.updateWindowBlur(glassObject)

		Scheduler.totalUpdate(glassObject)

		-- resumeUpdates may have inserted the object before parenting
		if not glassObject.Paused then
			GlassObject.addToUpdateList(glassObject)
		end
	end)

	return guiObject
end

function Window.addInstance(instance: Instance)
	if instance:IsA("GuiObject") then
		Window.setup(instance)
	end
end

function Window.removeInstance(instance: Instance)
	if instance:IsA("GuiObject") then
		local glassObject = GlassObject.byWindow[instance]
		if glassObject then
			GlassObject.byWindow[instance] = nil
			GlassObject.removeFromUpdateList(glassObject)

			-- The window may outlive its glass (untagging), so its handlers
			-- must not fire against the cleared object below
			for _, connection in glassObject.Connections do
				connection:Disconnect()
			end
			if glassObject.UICornerConnection then
				glassObject.UICornerConnection:Disconnect()
			end
			if glassObject.Geometry then
				Liquid.releaseGeometry(glassObject.Geometry)
			end
			if glassObject.EditableImage then
				glassObject.EditableImage:Destroy()
			end
			-- Evict the window's maps from the worker caches and cancel an
			-- in-flight finish thread (reads of the frozen record return
			-- nil, so its token check fails safely)
			Parallel.forget(glassObject)
			glassObject.FinishToken = nil
			-- The pane belongs to the library, so untagging removes it too;
			-- a no-op if the window's destruction already took it
			glassObject.Pane:Destroy()

			table.clear(glassObject)
			table.freeze(glassObject)
		end
	end
end

return Window
