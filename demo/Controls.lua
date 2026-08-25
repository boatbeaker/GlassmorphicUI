-- UI builders for control panel (right) and readout panel (left)
local UserInputService = game:GetService("UserInputService")

local ROW_HEIGHT = 36

local function addCorner(parent: Instance, radius: UDim)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = radius
	corner.Parent = parent
end

local function makeNameLabel(parent: Instance, text: string, size: UDim2, position: UDim2?): TextLabel
	local label = Instance.new("TextLabel")
	label.Font = Enum.Font.Gotham
	label.TextSize = 13
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextColor3 = Color3.fromRGB(220, 220, 230)
	label.BackgroundTransparency = 1
	label.Text = text
	label.Size = size
	if position then
		label.Position = position
	end
	label.ZIndex = 102
	label.Parent = parent
	return label
end

local Controls = {}

function Controls.create(screenGui: ScreenGui)
	local panel = Instance.new("ScrollingFrame")
	panel.Name = "Controls"
	panel.AnchorPoint = Vector2.new(1, 0)
	panel.Position = UDim2.new(1, -10, 0, 10)
	panel.Size = UDim2.new(0, 280, 1, -20)
	panel.BackgroundColor3 = Color3.fromRGB(24, 24, 32)
	panel.BackgroundTransparency = 0.1
	panel.BorderSizePixel = 0
	panel.ScrollBarThickness = 6
	panel.AutomaticCanvasSize = Enum.AutomaticSize.Y
	panel.CanvasSize = UDim2.new()
	panel.ZIndex = 100
	panel.Parent = screenGui

	local panelPadding = Instance.new("UIPadding")
	panelPadding.PaddingTop = UDim.new(0, 10)
	panelPadding.PaddingBottom = UDim.new(0, 10)
	panelPadding.PaddingLeft = UDim.new(0, 10)
	panelPadding.PaddingRight = UDim.new(0, 10)
	panelPadding.Parent = panel

	local panelLayout = Instance.new("UIListLayout")
	panelLayout.Padding = UDim.new(0, 6)
	panelLayout.SortOrder = Enum.SortOrder.LayoutOrder
	panelLayout.Parent = panel

	local rowOrder = 0

	local function makeRow(height: number): Frame
		rowOrder += 1
		local row = Instance.new("Frame")
		row.BackgroundTransparency = 1
		row.Size = UDim2.new(1, 0, 0, height)
		row.LayoutOrder = rowOrder
		row.ZIndex = 101
		row.Parent = panel
		return row
	end

	-- Global input handler for all sliders; active slider parks its updater here
	local activeSliderUpdate: ((x: number) -> ())? = nil
	UserInputService.InputChanged:Connect(function(input)
		local update = activeSliderUpdate
		if
			update
			and (
				input.UserInputType == Enum.UserInputType.MouseMovement
				or input.UserInputType == Enum.UserInputType.Touch
			)
		then
			update(input.Position.X)
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if
			input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch
		then
			activeSliderUpdate = nil
		end
	end)

	local builders = {}

	function builders.slider(
		label: string,
		min: number,
		max: number,
		default: number,
		step: number,
		onChanged: (number) -> ()
	)
		local row = makeRow(ROW_HEIGHT)

		makeNameLabel(row, label, UDim2.new(0.7, 0, 0, 16))

		local valueLabel = Instance.new("TextLabel")
		valueLabel.Font = Enum.Font.Gotham
		valueLabel.TextSize = 13
		valueLabel.TextXAlignment = Enum.TextXAlignment.Right
		valueLabel.TextColor3 = Color3.fromRGB(160, 190, 255)
		valueLabel.BackgroundTransparency = 1
		valueLabel.Size = UDim2.new(0.3, 0, 0, 16)
		valueLabel.Position = UDim2.fromScale(0.7, 0)
		valueLabel.ZIndex = 102
		valueLabel.Parent = row

		local track = Instance.new("Frame")
		track.BackgroundColor3 = Color3.fromRGB(60, 60, 75)
		track.BorderSizePixel = 0
		track.Size = UDim2.new(1, 0, 0, 4)
		track.Position = UDim2.fromOffset(0, 24)
		track.ZIndex = 102
		track.Parent = row
		addCorner(track, UDim.new(0.5, 0))

		local knob = Instance.new("Frame")
		knob.AnchorPoint = Vector2.new(0.5, 0.5)
		knob.BackgroundColor3 = Color3.fromRGB(120, 170, 255)
		knob.BorderSizePixel = 0
		knob.Size = UDim2.fromOffset(14, 14)
		knob.Position = UDim2.fromScale(0, 0.5)
		knob.ZIndex = 103
		knob.Parent = track
		addCorner(knob, UDim.new(0.5, 0))

		local function setValue(value: number, fromDrag: boolean)
			value = math.clamp(math.round(value / step) * step, min, max)
			knob.Position = UDim2.fromScale((value - min) / (max - min), 0.5)
			valueLabel.Text = if step >= 1 then string.format("%d", value) else string.format("%.2f", value)
			if fromDrag then
				onChanged(value)
			end
		end

		local function updateFromX(x: number)
			local alpha = math.clamp((x - track.AbsolutePosition.X) / math.max(track.AbsoluteSize.X, 1), 0, 1)
			setValue(min + alpha * (max - min), true)
		end

		-- Track is 4px tall; invisible frame below catches clicks
		local hitArea = Instance.new("Frame")
		hitArea.BackgroundTransparency = 1
		hitArea.Size = UDim2.new(1, 0, 0, 22)
		hitArea.Position = UDim2.fromOffset(0, 15)
		hitArea.ZIndex = 104
		hitArea.Parent = row

		hitArea.InputBegan:Connect(function(input)
			if
				input.UserInputType == Enum.UserInputType.MouseButton1
				or input.UserInputType == Enum.UserInputType.Touch
			then
				activeSliderUpdate = updateFromX
				updateFromX(input.Position.X)
			end
		end)

		setValue(default, false)

		return {
			-- Set value without triggering onChanged callback
			set = function(value: number)
				setValue(value, false)
			end,
		}
	end

	function builders.button(label: string, onClicked: () -> ())
		local row = makeRow(28)

		local button = Instance.new("TextButton")
		button.Font = Enum.Font.GothamBold
		button.TextSize = 13
		button.TextColor3 = Color3.fromRGB(160, 190, 255)
		button.BackgroundColor3 = Color3.fromRGB(60, 60, 75)
		button.BorderSizePixel = 0
		button.Size = UDim2.fromScale(1, 1)
		button.Text = label
		button.ZIndex = 102
		button.Parent = row
		addCorner(button, UDim.new(0, 6))

		button.Activated:Connect(onClicked)

		return {
			setText = function(text: string)
				button.Text = text
			end,
		}
	end

	function builders.checkbox(label: string, default: boolean, onChanged: (boolean) -> ())
		local row = makeRow(22)

		local checked = default

		local box = Instance.new("TextButton")
		box.Font = Enum.Font.GothamBold
		box.TextSize = 14
		box.TextColor3 = Color3.fromRGB(120, 170, 255)
		box.BackgroundColor3 = Color3.fromRGB(60, 60, 75)
		box.BorderSizePixel = 0
		box.Size = UDim2.fromOffset(18, 18)
		box.Text = if checked then "✓" else ""
		box.ZIndex = 102
		box.Parent = row
		addCorner(box, UDim.new(0, 4))

		makeNameLabel(row, label, UDim2.new(1, -26, 1, 0), UDim2.fromOffset(26, 0))

		box.Activated:Connect(function()
			checked = not checked
			box.Text = if checked then "✓" else ""
			onChanged(checked)
		end)
	end

	-- UDim inputs use two text boxes (scale and offset), not a slider
	function builders.udimInput(label: string, default: UDim, onChanged: (UDim) -> ())
		local row = makeRow(ROW_HEIGHT)

		makeNameLabel(row, label, UDim2.new(1, 0, 0, 14))

		local components: { [string]: number } = { Scale = default.Scale, Offset = default.Offset }
		local boxes: { [string]: TextBox } = {}

		-- Three decimals hides float32 artifacts
		local function formatComponent(value: number): string
			return tostring(math.round(value * 1000) / 1000)
		end

		local function makeComponentBox(key: string, x: UDim)
			local labelWidth = 44
			makeNameLabel(row, key, UDim2.fromOffset(labelWidth, 18), UDim2.new(x.Scale, x.Offset, 0, 16))

			local box = Instance.new("TextBox")
			box.Font = Enum.Font.Gotham
			box.TextSize = 13
			box.TextColor3 = Color3.fromRGB(160, 190, 255)
			box.BackgroundColor3 = Color3.fromRGB(60, 60, 75)
			box.BorderSizePixel = 0
			box.ClearTextOnFocus = false
			box.Text = formatComponent(components[key])
			box.Position = UDim2.new(x.Scale, x.Offset + labelWidth, 0, 16)
			box.Size = UDim2.new(0.5, -(labelWidth + x.Offset + 4), 0, 18)
			box.ZIndex = 102
			box.Parent = row
			boxes[key] = box
			addCorner(box, UDim.new(0, 4))

			box.FocusLost:Connect(function()
				local value = tonumber(box.Text)
				if value then
					components[key] = value
					onChanged(UDim.new(components.Scale, components.Offset))
				end
				-- Rewrite to show typo revert
				box.Text = formatComponent(components[key])
			end)
		end

		makeComponentBox("Scale", UDim.new(0, 0))
		makeComponentBox("Offset", UDim.new(0.5, 4))

		return {
			-- Set value without triggering onChanged callback
			set = function(value: UDim)
				components.Scale, components.Offset = value.Scale, value.Offset
				boxes.Scale.Text = formatComponent(value.Scale)
				boxes.Offset.Text = formatComponent(value.Offset)
			end,
		}
	end

	return builders
end

-- Left panel for debug readouts; line() adds a row with a value setter
function Controls.createReadouts(screenGui: ScreenGui)
	local panel = Instance.new("Frame")
	panel.Name = "Readouts"
	panel.Position = UDim2.new(0, 10, 1, -10)
	panel.AnchorPoint = Vector2.new(0, 1)
	panel.Size = UDim2.fromOffset(240, 0)
	panel.AutomaticSize = Enum.AutomaticSize.Y
	panel.BackgroundColor3 = Color3.fromRGB(24, 24, 32)
	panel.BackgroundTransparency = 0.1
	panel.BorderSizePixel = 0
	panel.ZIndex = 100
	panel.Parent = screenGui

	local panelPadding = Instance.new("UIPadding")
	panelPadding.PaddingTop = UDim.new(0, 10)
	panelPadding.PaddingBottom = UDim.new(0, 10)
	panelPadding.PaddingLeft = UDim.new(0, 10)
	panelPadding.PaddingRight = UDim.new(0, 10)
	panelPadding.Parent = panel

	local panelLayout = Instance.new("UIListLayout")
	panelLayout.Padding = UDim.new(0, 4)
	panelLayout.SortOrder = Enum.SortOrder.LayoutOrder
	panelLayout.Parent = panel

	local rowOrder = 0

	return {
		line = function(label: string): (value: string) -> ()
			rowOrder += 1
			local row = Instance.new("Frame")
			row.BackgroundTransparency = 1
			row.Size = UDim2.new(1, 0, 0, 16)
			row.LayoutOrder = rowOrder
			row.ZIndex = 101
			row.Parent = panel

			makeNameLabel(row, label, UDim2.fromScale(0.55, 1))

			local valueLabel = Instance.new("TextLabel")
			valueLabel.Font = Enum.Font.Gotham
			valueLabel.TextSize = 13
			valueLabel.TextXAlignment = Enum.TextXAlignment.Right
			valueLabel.TextColor3 = Color3.fromRGB(160, 190, 255)
			valueLabel.BackgroundTransparency = 1
			valueLabel.Text = "—"
			valueLabel.Size = UDim2.fromScale(0.45, 1)
			valueLabel.Position = UDim2.fromScale(0.55, 0)
			valueLabel.ZIndex = 102
			valueLabel.Parent = row

			return function(value: string)
				valueLabel.Text = value
			end
		end,
	}
end

return Controls
