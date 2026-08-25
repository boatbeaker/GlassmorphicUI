-- OS-style widgets with live content; see Widgets.list for available widgets
local TweenService = game:GetService("TweenService")

local GlassmorphicUI = require(script.Parent.GlassmorphicUI)

local ORANGE = Color3.fromRGB(255, 159, 10)
local BLUE = Color3.fromRGB(64, 156, 255)
local WHITE = Color3.fromRGB(255, 255, 255)
local PADDING = 10

local PLAYER_WIDTH, PLAYER_HEIGHT = 220, 130
local PLAYER_CORNER_RADIUS = UDim.new(0, 24)
local NAVBAR_WIDTH, NAVBAR_HEIGHT = 300, 80
local NAVBAR_CORNER_RADIUS = UDim.new(0.5, 0)
local CIRCLE_SIZE = 150
local CIRCLE_CORNER_RADIUS = UDim.new(0.5, 0)

local Widgets = {}

local function formatClock(seconds: number): string
	return string.format("%d:%02d", seconds // 60, seconds % 60)
end

local function addCorner(parent: Instance, radius: UDim): UICorner
	local corner = Instance.new("UICorner")
	corner.CornerRadius = radius
	corner.Parent = parent
	return corner
end

-- Two rounded vertical bars, the pause glyph, centered in the parent
local function makePauseBars(parent: Instance, height: number, color: Color3)
	local barWidth = math.max(math.round(height * 0.28), 3)
	for i = 1, 2 do
		local bar = Instance.new("Frame")
		bar.AnchorPoint = Vector2.new(0.5, 0.5)
		bar.Position = UDim2.new(0.5, (if i == 1 then -1 else 1) * barWidth * 0.75, 0.5, 0)
		bar.Size = UDim2.fromOffset(barWidth, height)
		bar.BackgroundColor3 = color
		bar.BorderSizePixel = 0
		bar.ZIndex = 3
		addCorner(bar, UDim.new(0.5, 0))
		bar.Parent = parent
	end
end

local function makeGlyphButton(parent: Instance, text: string, textSize: number, position: UDim2): TextButton
	local button = Instance.new("TextButton")
	button.AnchorPoint = Vector2.new(0.5, 0.5)
	button.Position = position
	button.Size = UDim2.fromOffset(30, 30)
	button.BackgroundTransparency = 1
	button.Font = Enum.Font.SourceSansBold
	button.TextSize = textSize
	button.TextColor3 = WHITE
	button.Text = text
	button.ZIndex = 2
	button.Parent = parent
	return button
end

function Widgets.createMediaPlayer(parent: Instance)
	local window = GlassmorphicUI.new()
	window.Name = "MediaWidget"
	window.AnchorPoint = Vector2.new(0.5, 0.5)
	window.Position = UDim2.fromScale(0.4, 0.5)
	window.Size = UDim2.fromOffset(PLAYER_WIDTH, PLAYER_HEIGHT)

	local corner = addCorner(window, PLAYER_CORNER_RADIUS)

	local albumArt = Instance.new("ImageLabel")
	albumArt.Position = UDim2.fromOffset(PADDING, PADDING)
	albumArt.Size = UDim2.fromOffset(44, 44)
	albumArt.BackgroundColor3 = Color3.fromRGB(40, 30, 60)
	albumArt.BorderSizePixel = 0
	albumArt.Image = "rbxassetid://16620841089"
	albumArt.ScaleType = Enum.ScaleType.Crop
	albumArt.ZIndex = 2
	albumArt.Parent = window
	addCorner(albumArt, UDim.new(0, 10))

	local title = Instance.new("TextLabel")
	title.Position = UDim2.fromOffset(62, 12)
	title.Size = UDim2.new(1, -100, 0, 16)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBold
	title.TextSize = 15
	title.TextColor3 = WHITE
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Text = "Glassmorphic"
	title.ZIndex = 2
	title.Parent = window

	local artist = Instance.new("TextLabel")
	artist.Position = UDim2.fromOffset(62, 30)
	artist.Size = UDim2.new(1, -100, 0, 14)
	artist.BackgroundTransparency = 1
	artist.Font = Enum.Font.Gotham
	artist.TextSize = 12
	artist.TextColor3 = Color3.fromRGB(235, 235, 240)
	artist.TextXAlignment = Enum.TextXAlignment.Left
	artist.Text = "by boatbomber"
	artist.ZIndex = 2
	artist.Parent = window

	-- Equalizer glyph in the top-right corner
	local equalizer = Instance.new("Frame")
	equalizer.AnchorPoint = Vector2.new(1, 0)
	equalizer.Position = UDim2.new(1, -PADDING, 0, 14)
	equalizer.Size = UDim2.fromOffset(14, 13)
	equalizer.BackgroundTransparency = 1
	equalizer.ZIndex = 2
	equalizer.Parent = window
	for i, height in { 6, 10, 13, 8 } do
		local bar = Instance.new("Frame")
		bar.AnchorPoint = Vector2.new(0, 1)
		bar.Position = UDim2.new(0, (i - 1) * 4, 1, 0)
		bar.Size = UDim2.fromOffset(2, height)
		bar.BackgroundColor3 = WHITE
		bar.BorderSizePixel = 0
		bar.ZIndex = 3
		addCorner(bar, UDim.new(0.5, 0))
		bar.Parent = equalizer
	end

	local elapsedLabel = Instance.new("TextLabel")
	elapsedLabel.Position = UDim2.new(0, PADDING, 1, -48)
	elapsedLabel.Size = UDim2.fromOffset(50, 12)
	elapsedLabel.BackgroundTransparency = 1
	elapsedLabel.Font = Enum.Font.Gotham
	elapsedLabel.TextSize = 10
	elapsedLabel.TextColor3 = WHITE
	elapsedLabel.TextTransparency = 0.2
	elapsedLabel.TextXAlignment = Enum.TextXAlignment.Left
	elapsedLabel.ZIndex = 2
	elapsedLabel.Parent = window

	local remainingLabel = Instance.new("TextLabel")
	remainingLabel.AnchorPoint = Vector2.new(1, 0)
	remainingLabel.Position = UDim2.new(1, -PADDING, 1, -48)
	remainingLabel.Size = UDim2.fromOffset(50, 12)
	remainingLabel.BackgroundTransparency = 1
	remainingLabel.Font = Enum.Font.Gotham
	remainingLabel.TextSize = 10
	remainingLabel.TextColor3 = WHITE
	remainingLabel.TextTransparency = 0.2
	remainingLabel.TextXAlignment = Enum.TextXAlignment.Right
	remainingLabel.ZIndex = 2
	remainingLabel.Parent = window

	local track = Instance.new("Frame")
	track.Position = UDim2.new(0, PADDING, 1, -38)
	track.Size = UDim2.new(1, -PADDING * 2, 0, 3)
	track.BackgroundColor3 = WHITE
	track.BackgroundTransparency = 0.6
	track.BorderSizePixel = 0
	track.ZIndex = 2
	track.Parent = window
	addCorner(track, UDim.new(0.5, 0))

	local fill = Instance.new("Frame")
	fill.Size = UDim2.fromScale(0, 1)
	fill.BackgroundColor3 = WHITE
	fill.BorderSizePixel = 0
	fill.ZIndex = 3
	fill.Parent = track
	addCorner(fill, UDim.new(0.5, 0))

	local starButton = makeGlyphButton(window, "★", 20, UDim2.new(0.11, 0, 1, -19))
	local previousButton = makeGlyphButton(window, "◀◀", 16, UDim2.new(0.305, 0, 1, -19))
	local nextButton = makeGlyphButton(window, "▶▶", 16, UDim2.new(0.695, 0, 1, -19))

	-- A glyph button with no glyph: the pause bars are frames, since no
	-- font renders a pause glyph with rounded bars
	local pauseButton = makeGlyphButton(window, "", 16, UDim2.new(0.5, 0, 1, -19))
	makePauseBars(pauseButton, 16, WHITE)

	-- Picture-in-picture glyph: an outlined screen with a filled corner
	local pip = Instance.new("Frame")
	pip.AnchorPoint = Vector2.new(0.5, 0.5)
	pip.Position = UDim2.new(0.89, 0, 1, -19)
	pip.Size = UDim2.fromOffset(20, 15)
	pip.BackgroundTransparency = 1
	pip.ZIndex = 2
	pip.Parent = window
	local pipStroke = Instance.new("UIStroke")
	pipStroke.Color = WHITE
	pipStroke.Thickness = 1.5
	pipStroke.Parent = pip
	addCorner(pip, UDim.new(0, 5))
	local pipInner = Instance.new("Frame")
	pipInner.AnchorPoint = Vector2.new(1, 1)
	pipInner.Position = UDim2.new(1, -2, 1, -2)
	pipInner.Size = UDim2.fromOffset(8, 5)
	pipInner.BackgroundColor3 = WHITE
	pipInner.BorderSizePixel = 0
	pipInner.ZIndex = 3
	pipInner.Parent = pip
	addCorner(pipInner, UDim.new(0, 2))

	local length = 5 * 60 + 9
	local elapsed = 12
	local playing = true
	local starred = false

	local function refresh()
		elapsedLabel.Text = formatClock(elapsed)
		remainingLabel.Text = "-" .. formatClock(length - elapsed)
		fill.Size = UDim2.fromScale(elapsed / length, 1)
	end
	refresh()

	starButton.Activated:Connect(function()
		starred = not starred
		starButton.TextColor3 = if starred then ORANGE else WHITE
	end)
	previousButton.Activated:Connect(function()
		elapsed = 0
		refresh()
	end)
	nextButton.Activated:Connect(function()
		elapsed = (elapsed + 30) % length
		refresh()
	end)
	pauseButton.Activated:Connect(function()
		playing = not playing
	end)

	task.spawn(function()
		while true do
			task.wait(1)
			if playing then
				elapsed = (elapsed + 1) % length
				refresh()
			end
		end
	end)

	window.Parent = parent

	return {
		window = window,
		uiCorner = corner,
	}
end

function Widgets.createNavbar(parent: Instance)
	local window = GlassmorphicUI.new()
	window.Name = "NavbarWidget"
	window.AnchorPoint = Vector2.new(0.5, 0.5)
	window.Position = UDim2.fromScale(0.4, 0.5)
	window.Size = UDim2.fromOffset(NAVBAR_WIDTH, NAVBAR_HEIGHT)
	-- A plain ellipse profile (superellipse 2) with a full-scale corner,
	-- so the glass silhouette hugs the selection pill's round ends
	window:SetAttribute("SuperEllipseFactor", 2)

	local corner = addCorner(window, NAVBAR_CORNER_RADIUS)

	-- Icons come from a shared sprite sheet, one 128x128 cell each
	local items = {
		{ name = "Quests", iconOffset = Vector2.new(516, 260) },
		{ name = "Tutorials", iconOffset = Vector2.new(0, 520) },
		{ name = "Lessons", iconOffset = Vector2.new(0, 390) },
	}

	-- The selection pill: a translucent frame that slides under whichever
	-- item was clicked
	local highlight = Instance.new("Frame")
	highlight.AnchorPoint = Vector2.new(0.5, 0.5)
	highlight.Position = UDim2.fromScale(0.5 / #items, 0.5)
	highlight.Size = UDim2.new(1 / #items, -10, 1, -14)
	highlight.BackgroundColor3 = WHITE
	highlight.BackgroundTransparency = 0.75
	highlight.BorderSizePixel = 0
	highlight.ZIndex = 2
	highlight.Parent = window
	addCorner(highlight, UDim.new(0.5, 0))

	local rows = {}
	for index, item in items do
		local button = Instance.new("TextButton")
		button.Position = UDim2.fromScale((index - 1) / #items, 0)
		button.Size = UDim2.fromScale(1 / #items, 1)
		button.BackgroundTransparency = 1
		button.Text = ""
		button.ZIndex = 3
		button.Parent = window

		local icon = Instance.new("ImageLabel")
		icon.AnchorPoint = Vector2.new(0.5, 0.5)
		icon.Position = UDim2.new(0.5, 0, 0.5, -14)
		icon.Size = UDim2.fromOffset(32, 32)
		icon.BackgroundTransparency = 1
		icon.Image = "rbxassetid://16029057314"
		icon.ImageRectSize = Vector2.new(128, 128)
		icon.ImageRectOffset = item.iconOffset
		icon.ZIndex = 4
		icon.Parent = button

		local label = Instance.new("TextLabel")
		label.AnchorPoint = Vector2.new(0.5, 0)
		label.Position = UDim2.new(0.5, 0, 0.5, 4)
		label.Size = UDim2.fromOffset(60, 16)
		label.BackgroundTransparency = 1
		label.Font = Enum.Font.GothamMedium
		label.TextSize = 13
		label.TextColor3 = WHITE
		label.Text = item.name
		label.ZIndex = 4
		label.Parent = button

		rows[index] = { button = button, icon = icon, label = label }
	end

	-- Selecting an item slides the pill under it and shifts the item's
	-- icon and label to blue, fading the others back to white
	local tweenInfo = TweenInfo.new(0.25, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
	local function setSelected(selectedIndex: number)
		TweenService:Create(highlight, tweenInfo, {
			Position = UDim2.fromScale((selectedIndex - 0.5) / #items, 0.5),
		}):Play()
		for index, row in rows do
			local color = if index == selectedIndex then BLUE else WHITE
			TweenService:Create(row.icon, tweenInfo, { ImageColor3 = color }):Play()
			TweenService:Create(row.label, tweenInfo, { TextColor3 = color }):Play()
		end
	end
	for index, row in rows do
		row.button.Activated:Connect(function()
			setSelected(index)
		end)
	end
	setSelected(1)

	window.Parent = parent

	return {
		window = window,
		uiCorner = corner,
	}
end

-- An empty circle of plain glass: no content, just the material itself
function Widgets.createCircle(parent: Instance)
	local window = GlassmorphicUI.new()
	window.Name = "CircleWidget"
	window.AnchorPoint = Vector2.new(0.5, 0.5)
	window.Position = UDim2.fromScale(0.4, 0.5)
	window.Size = UDim2.fromOffset(CIRCLE_SIZE, CIRCLE_SIZE)
	-- Superellipse 2 turns the rounded rect into a true circle
	window:SetAttribute("SuperEllipseFactor", 2)

	local corner = addCorner(window, CIRCLE_CORNER_RADIUS)

	window.Parent = parent

	return {
		window = window,
		uiCorner = corner,
	}
end

-- The demo's switcher cycles through this list. Each builder sets its own
-- size and corner, since a pill navbar and a card want different shapes;
-- the demo's controls read those back off the created widget.
Widgets.list = {
	{ name = "Media Player", create = Widgets.createMediaPlayer },
	{ name = "Navbar", create = Widgets.createNavbar },
	{ name = "Circle", create = Widgets.createCircle },
}

return Widgets
