local GlassmorphicUI = require(script.GlassmorphicUI)

local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "GlassmorphicUIDemo"
ScreenGui.IgnoreGuiInset = true
ScreenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
ScreenGui.Parent = script.Parent

local background = Instance.new("ImageLabel")
background.Name = "Background"
background.Size = UDim2.fromScale(0.5, 1)
background.Image = "rbxassetid://16606410725"
background.ZIndex = 0
background.Parent = ScreenGui

local blurryWindow = GlassmorphicUI.new()
blurryWindow.BackgroundTransparency = 0.7
blurryWindow.Position = UDim2.fromScale(0.5, 0.3)
blurryWindow.BackgroundColor3 = Color3.fromRGB(7, 48, 84)
blurryWindow.Size = UDim2.fromScale(0.3, 0.3)
blurryWindow.AnchorPoint = Vector2.new(0.5, 0.5)

local uiCorner = Instance.new("UICorner")
uiCorner.CornerRadius = UDim.new(0.08, 0)
uiCorner.Parent = blurryWindow

local textLabel = Instance.new("TextLabel")
textLabel.Font = Enum.Font.GothamBold
textLabel.TextScaled = true
textLabel.Text = "GlassmorphicUI by boatbomber"
textLabel.BackgroundTransparency = 1
textLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
textLabel.Size = UDim2.new(1, 0, 0.09, 0)
textLabel.Position = UDim2.fromScale(0, 0.1)
textLabel.Parent = blurryWindow

-- Make the window move in a circle
task.spawn(function()
	local x, y
	while true do
		x = (math.cos(os.clock() * 2) / 3) + 0.5
		y = (math.sin(os.clock() * 2) / 3) + 0.5
		blurryWindow.Position = UDim2.fromScale(x, y)
		task.wait()
	end
end)

blurryWindow.Parent = ScreenGui
