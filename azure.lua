-- Services.
local playersService = game:GetService("Players")
local workspaceService = game:GetService("Workspace")
local userInputService = game:GetService("UserInputService")
local virtualInput = game:GetService("VirtualInputManager")

local localPlayer = playersService.LocalPlayer

-- Config. Observacoes gravadas do jogo, nao confirmadas como limiar de green.
local CONFIG = {
	toggleKey = Enum.KeyCode.Insert,
	characterFolder = "Characters",
	meterName = "FunnelMeter",
	offsetAttr = "meterOffset",
	infiniteStamina = true,
	autoRelease = true,
	autoShoot = true,
	staminaMax = 100,
	observedFloor = -0.98246,
	observedSpeed = 1.8,
	observedSweepTime = 0.435,
	autoLearn = true,
	releaseTarget = -0.975,
	learnMargin = 0.005,
	adjustStep = 0.005,
	stopReleaseDelay = 0.12,
	shootDelay = 0.35,
	shootKeyCode = 69,
	tickRate = 0.01,
}

-- State.
local loaded = true
local staminaCeiling = 0
local staminaHolder = nil
local staminaRetry = 0
local learnedFloor = CONFIG.observedFloor
local activeOffsetAttr = nil
local targetOverride = nil
local lastOffset = nil
local lastMoveClock = 0
local lastOffsetChange = 0
local cycleStart = nil
local cycleMin = nil
local cyclePress = false
local keyHeld = false
local movedOnce = false
local released = false
local pressTime = nil
local nextShotAt = 0
local releaseCooldown = 0
local statusClock = 0
local shotCount = 0
local shotOffsets = {}
local lastAction = nil
local lastReleasedShot = nil
local lastMeterIndex = nil
local lastError = nil
local inspectedCharacter = nil
local toggleConnection, dragEndConnection = nil, nil

-- Personagem com varios caminhos de fallback.
local function getCharacter()
	local folder = workspaceService:FindFirstChild(CONFIG.characterFolder)
	if folder then
		local exact = folder:FindFirstChild(localPlayer.Name)
		if exact then return exact end
		for _, child in ipairs(folder:GetChildren()) do
			if child.Name == localPlayer.DisplayName then return child end
		end
	end
	return localPlayer.Character or workspaceService:FindFirstChild(localPlayer.Name)
end

local function getMeter(character)
	local hrp = character:FindFirstChild("HumanoidRootPart")
	return hrp and hrp:FindFirstChild(CONFIG.meterName)
end

-- Acha o atributo do offset: o oficial, ou qualquer numerico com offset/meter no nome.
local function resolveOffsetAttribute(character)
	local attrs = character:GetAttributes()
	if typeof(attrs[CONFIG.offsetAttr]) == "number" then return CONFIG.offsetAttr end
	local fallback = nil
	for name, value in pairs(attrs) do
		if typeof(value) == "number" then
			local lowered = string.lower(name)
			if string.find(lowered, "offset", 1, true) or string.find(lowered, "meter", 1, true) then
				fallback = name
			end
		end
	end
	return fallback
end

-- Scan completo: arvore do meter, atributos do personagem e gradients.
local function inspect(character)
	print("[Azure Hub] ===== scan =====")
	print("personagem: " .. character:GetFullName())
	print(string.format("observados: speed=%s sweep=%.3fs piso=%s",
		tostring(CONFIG.observedSpeed), CONFIG.observedSweepTime, tostring(CONFIG.observedFloor)))
	for name, value in pairs(character:GetAttributes()) do
		print(string.format("attr %s = %s (%s)", name, tostring(value), type(value)))
	end

	local meter = getMeter(character)
	if not meter then
		warn("[Azure Hub] " .. CONFIG.meterName .. " nao encontrado")
		return
	end

	local function walk(inst, depth)
		print(string.rep("  ", depth + 1) .. inst.Name .. " : " .. inst.ClassName)
		if inst:IsA("UIGradient") then
			print(string.rep("  ", depth + 2) .. "offset=" .. tostring(inst.Offset) .. " rotation=" .. tostring(inst.Rotation))
			for i, key in ipairs(inst:GetKeypoints()) do
				print(string.rep("  ", depth + 2) .. string.format(
					"kp%d pos=%.3f col=(%.2f,%.2f,%.2f) transp=%.2f",
					i, key.Position, key.Color.R, key.Color.G, key.Color.B, key.Transparency))
			end
		end
		for _, child in ipairs(inst:GetChildren()) do
			walk(child, depth + 1)
		end
	end
	walk(meter, 0)
	print("[Azure Hub] offset inicial = " .. tostring(character:GetAttribute(CONFIG.offsetAttr)))
end

-- Input: so usa keypress/keyrelease se existir o par completo, senao VirtualInputManager.
local pairedKeys = typeof(keypress) == "function" and typeof(keyrelease) == "function"

local function pressShoot()
	if keyHeld then return end
	pcall(function()
		if pairedKeys then
			keypress(CONFIG.shootKeyCode)
		else
			virtualInput:SendKeyEvent(true, Enum.KeyCode.E, game, false)
		end
	end)
	keyHeld = true
end

local function releaseShoot()
	pcall(function()
		if pairedKeys then
			keyrelease(CONFIG.shootKeyCode)
		else
			virtualInput:SendKeyEvent(false, Enum.KeyCode.E, game, false)
		end
	end)
	-- Rescate: se a tecla continuar pra baixo, manda subir por outro caminho.
	pcall(function()
		if userInputService:IsKeyDown(Enum.KeyCode.E) then
			virtualInput:SendKeyEvent(false, Enum.KeyCode.E, game, false)
			if typeof(keyrelease) == "function" then
				keyrelease(CONFIG.shootKeyCode)
			end
		end
	end)
	keyHeld = false
end

-- Acha onde a stamina mora: character, humanoid, player ou Value.
local function resolveStaminaHolder(character)
	local sources = { character, character:FindFirstChildOfClass("Humanoid"), localPlayer }
	for _, inst in ipairs(sources) do
		if inst and typeof(inst:GetAttribute("Stamina")) == "number" then
			return inst
		end
	end
	for _, inst in ipairs(character:GetDescendants()) do
		if string.find(string.lower(inst.Name), "stam", 1, true) then
			if inst:IsA("ValueBase") and typeof(inst.Value) == "number" then return inst end
			if typeof(inst:GetAttribute("Stamina")) == "number" then return inst end
		end
	end
	return nil
end

-- Sobe a stamina, nunca rebaixa: aprende o teto pelo maior valor visto.
local function fillStamina(holder)
	local value
	if holder:IsA("ValueBase") then
		value = holder.Value
	else
		value = holder:GetAttribute("Stamina")
	end
	if typeof(value) ~= "number" then return end
	if value > staminaCeiling then
		staminaCeiling = value
	end
	local target = math.max(staminaCeiling, CONFIG.staminaMax)
	if value < target then
		if holder:IsA("ValueBase") then
			holder.Value = target
		else
			holder:SetAttribute("Stamina", target)
		end
	end
end

-- Alvo: manual (botoes da UI), aprendido do piso, ou valor fixo da Config.
local function getTarget()
	if targetOverride then return targetOverride end
	if CONFIG.autoLearn then
		return learnedFloor + CONFIG.learnMargin
	end
	return CONFIG.releaseTarget
end

-- Ciclo do meter: desce de 0 ate o piso (~-0.98246) em ~0.43s nas gravacoes.
local function updateAutoTime(character, now, offset, autoShoot)
	if typeof(offset) ~= "number" then
		lastOffset = nil
		if pressTime and now - pressTime > 0.5 then
			releaseShoot()
			pressTime = nil
		end
		return
	end

	local prev = lastOffset
	local resting = offset > -0.02

	-- Fim de ciclo: medidor voltou ao descanso.
	if resting or (lastOffset and offset > lastOffset + 0.05) then
		if cycleStart and not released and cyclePress and cycleMin then
			-- Nosso sweep terminou sem soltar: o minimo visto e o piso real.
			learnedFloor = cycleMin
			print(string.format("[Azure Hub] ciclo sem release | min=%.5f | piso ajustado", cycleMin))
		end
		if keyHeld then
			releaseShoot()
		end
		released = false
		pressTime = nil
		cycleStart = nil
		cycleMin = nil
		cyclePress = false
		movedOnce = false
	end

	local active = offset <= -0.02

	if active then
		cycleMin = (cycleMin and math.min(cycleMin, offset)) or offset
		if cycleStart == nil then
			cycleStart = now
			lastMoveClock = now
		end
		if prev ~= nil and math.abs(offset - prev) >= 0.0005 then
			lastMoveClock = now
			lastOffsetChange = now
			movedOnce = true
		end
	end

	lastOffset = offset

	-- Auto shoot: aperta no descanso, sempre com tecla limpa entre cliques.
	if autoShoot and not released and not active and pressTime == nil
		and not keyHeld and now >= nextShotAt and now >= releaseCooldown then
		pressShoot()
		cyclePress = true
		pressTime = now
	end

	-- Cancela a tecla se o medidor nao comecou a descer (sem bola).
	if pressTime and not active and now - pressTime > 0.4 then
		releaseShoot()
		pressTime = nil
		nextShotAt = now + 0.6
		return
	end
	if pressTime and active then
		pressTime = nil
	end

	if released or not active then return end

	local target = getTarget()
	local reached = offset <= target
	local stopped = movedOnce and now - lastMoveClock > CONFIG.stopReleaseDelay
	local overtime = cycleStart and now - cycleStart > CONFIG.observedSweepTime * 2

	-- Solta no alvo, quando para, ou no overtime: nunca fica preso segurando.
	if reached or stopped or overtime then
		releaseShoot()
		released = true
		pressTime = nil
		shotCount = shotCount + 1
		table.insert(shotOffsets, offset)
		-- Solto mais raso que o meta: o alvo era inalcancavel, corrige o piso.
		if offset > target then
			learnedFloor = offset
		end
		local elapsed = cycleStart and (now - cycleStart) or 0
		print(string.format(
			"[Azure Hub] tiro %d | offset=%.5f | piso=%.5f | meta=%.5f | %.3fs | E=%s | speed=%s | action=%s",
			shotCount, offset, learnedFloor, target, elapsed,
			tostring(userInputService:IsKeyDown(Enum.KeyCode.E)),
			tostring(character:GetAttribute("ShotSpeed")),
			tostring(character:GetAttribute("Action"))))
		nextShotAt = now + CONFIG.shootDelay
		releaseCooldown = now + 0.1
	end
end

-- Ui.
local function round(inst, radius)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, radius)
	corner.Parent = inst
end

local function outline(inst, color, transparency)
	local stroke = Instance.new("UIStroke")
	stroke.Color = color
	stroke.Transparency = transparency
	stroke.Thickness = 1
	stroke.Parent = inst
end

local azure = Color3.fromRGB(25, 130, 255)
local onColor = Color3.fromRGB(25, 120, 235)
local offColor = Color3.fromRGB(48, 52, 64)

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "AzureHub"
screenGui.ResetOnSpawn = false
screenGui.Parent = localPlayer:WaitForChild("PlayerGui")

local panel = Instance.new("Frame")
panel.Size = UDim2.fromOffset(210, 282)
panel.Position = UDim2.fromOffset(28, 130)
panel.BackgroundColor3 = Color3.fromRGB(12, 16, 24)
panel.BorderSizePixel = 0
panel.Active = true
panel.Parent = screenGui
round(panel, 8)
outline(panel, azure, 0.55)

local header = Instance.new("Frame")
header.Size = UDim2.new(1, 0, 0, 30)
header.BackgroundColor3 = Color3.fromRGB(15, 21, 33)
header.BorderSizePixel = 0
header.Parent = panel
round(header, 8)

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -40, 1, 0)
title.Position = UDim2.fromOffset(10, 0)
title.BackgroundTransparency = 1
title.Font = Enum.Font.GothamBold
title.TextSize = 13
title.TextColor3 = azure
title.TextXAlignment = Enum.TextXAlignment.Left
title.Text = "AZURE HUB"
title.Parent = header

local hideButton = Instance.new("TextButton")
hideButton.Size = UDim2.fromOffset(26, 26)
hideButton.Position = UDim2.new(1, -28, 0, 2)
hideButton.BackgroundTransparency = 1
hideButton.Font = Enum.Font.GothamBold
hideButton.TextSize = 14
hideButton.TextColor3 = Color3.fromRGB(180, 190, 205)
hideButton.Text = "x"
hideButton.Parent = header
hideButton.Activated:Connect(function()
	panel.Visible = false
end)

local function makeLabel(text, y, size, color)
	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, -20, 0, size)
	label.Position = UDim2.fromOffset(10, y)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.Gotham
	label.TextSize = 11
	label.TextColor3 = color
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Text = text
	label.Parent = panel
	return label
end

local offsetLabel = makeLabel("Offset: --", 38, 16, Color3.fromRGB(200, 205, 215))
local actionLabel = makeLabel("Action: --", 56, 16, Color3.fromRGB(200, 205, 215))
local metaLabel = makeLabel("Meta: --", 74, 16, Color3.fromRGB(120, 170, 255))
local diagLabel = makeLabel("CH: -- | AT: -- | MV: -- | ST: --", 92, 16, Color3.fromRGB(255, 190, 90))

-- Ajuste fino do alvo ao vivo.
local adjustLabel = makeLabel("Alvo:", 113, 24, Color3.fromRGB(200, 205, 215))
adjustLabel.Size = UDim2.fromOffset(44, 24)

local function smallButton(text, x, width, color, callback)
	local button = Instance.new("TextButton")
	button.Size = UDim2.fromOffset(width, 24)
	button.Position = UDim2.fromOffset(x, 112)
	button.BackgroundColor3 = color
	button.BorderSizePixel = 0
	button.AutoButtonColor = false
	button.Font = Enum.Font.GothamBold
	button.TextSize = 11
	button.TextColor3 = Color3.fromRGB(255, 255, 255)
	button.Text = text
	button.Parent = panel
	round(button, 5)
	button.Activated:Connect(callback)
	return button
end

smallButton("-", 54, 26, offColor, function()
	targetOverride = math.max(getTarget() + CONFIG.adjustStep, learnedFloor)
	print("[Azure Hub] alvo manual (mais cedo) = " .. string.format("%.4f", targetOverride))
end)

smallButton("+", 84, 26, offColor, function()
	targetOverride = math.max(getTarget() - CONFIG.adjustStep, learnedFloor)
	print("[Azure Hub] alvo manual (mais fundo) = " .. string.format("%.4f", targetOverride))
end)

smallButton("AUTO", 114, 50, onColor, function()
	targetOverride = nil
	print("[Azure Hub] alvo automatico = " .. string.format("%.4f", getTarget()))
end)

local function createToggle(label, y, initial)
	local state = initial
	local button = Instance.new("TextButton")
	button.Size = UDim2.new(1, -20, 0, 30)
	button.Position = UDim2.fromOffset(10, y)
	button.BorderSizePixel = 0
	button.AutoButtonColor = false
	button.Font = Enum.Font.GothamMedium
	button.TextSize = 13
	button.TextColor3 = Color3.fromRGB(255, 255, 255)
	button.Parent = panel
	round(button, 6)

	local function paint()
		button.Text = label .. (state and ": ON" or ": OFF")
		button.BackgroundColor3 = state and onColor or offColor
	end
	paint()

	button.Activated:Connect(function()
		state = not state
		paint()
	end)

	return function()
		return state
	end
end

local staminaGetter = createToggle("Stamina infinita", 144, CONFIG.infiniteStamina)
local releaseGetter = createToggle("Auto release", 180, CONFIG.autoRelease)
local shootGetter = createToggle("Auto shoot", 216, CONFIG.autoShoot)

local hint = makeLabel("Insert mostra/esconde", 253, 16, Color3.fromRGB(130, 138, 152))
hint.Size = UDim2.new(1, -86, 0, 16)

local unloadButton = Instance.new("TextButton")
unloadButton.Size = UDim2.fromOffset(68, 22)
unloadButton.Position = UDim2.new(1, -78, 0, 250)
unloadButton.BackgroundColor3 = Color3.fromRGB(88, 28, 36)
unloadButton.BorderSizePixel = 0
unloadButton.Font = Enum.Font.GothamBold
unloadButton.TextSize = 10
unloadButton.TextColor3 = Color3.fromRGB(255, 120, 130)
unloadButton.Text = "UNLOAD"
unloadButton.Parent = panel
round(unloadButton, 5)

local function unload()
	loaded = false
	if pressTime or keyHeld then
		releaseShoot()
		pressTime = nil
	end
	if #shotOffsets > 0 then
		print("[Azure Hub] offsets gravados (" .. #shotOffsets .. "):")
		for i, value in ipairs(shotOffsets) do
			print(string.format("Shot %d: %.5f", i, value))
		end
	end
	if toggleConnection then toggleConnection:Disconnect() end
	if dragEndConnection then dragEndConnection:Disconnect() end
	screenGui:Destroy()
	print("[Azure Hub] descarregado")
end

unloadButton.Activated:Connect(unload)

-- Drag do painel pela barra de cima.
local dragging, dragStart, startPos = false, nil, nil
header.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		dragging = true
		dragStart = input.Position
		startPos = panel.Position
	end
end)
header.InputChanged:Connect(function(input)
	if dragging and input.UserInputType == Enum.UserInputType.MouseMovement then
		local delta = input.Position - dragStart
		panel.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
	end
end)
dragEndConnection = userInputService.InputEnded:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		dragging = false
	end
end)

toggleConnection = userInputService.InputBegan:Connect(function(input, processed)
	if processed then return end
	if input.KeyCode == CONFIG.toggleKey then
		panel.Visible = not panel.Visible
	end
end)

-- Um tick completo: qualquer erro vira aviso na UI e no console sem matar o loop.
local function tickBody(now)
	local character = getCharacter()
	if not character then
		lastOffset = nil
		diagLabel.Text = "CH: -- | AT: -- | MV: -- | ST: --"
		return
	end

	if character ~= inspectedCharacter then
		inspectedCharacter = character
		lastOffset, cycleStart, released, pressTime, movedOnce = nil, nil, false, nil, false
		cycleMin, cyclePress = nil, false
		if keyHeld then
			releaseShoot()
		end
		lastAction = nil
		lastReleasedShot = nil
		lastMeterIndex = nil
		staminaHolder = nil
		staminaRetry = 0
		activeOffsetAttr = resolveOffsetAttribute(character)
		inspect(character)
		print(string.format("[Azure Hub] attr do offset: %s | piso=%.5f | meta=%.5f",
			tostring(activeOffsetAttr), learnedFloor, getTarget()))
		if not activeOffsetAttr then
			warn("[Azure Hub] nenhum atributo de offset encontrado - veja o scan acima")
		end
	end

	if (not staminaHolder or not staminaHolder.Parent) and now >= staminaRetry then
		staminaRetry = now + 1
		staminaHolder = resolveStaminaHolder(character)
		if staminaHolder then
			print("[Azure Hub] stamina em: " .. staminaHolder:GetFullName())
		end
	end

	if staminaGetter() and staminaHolder then
		fillStamina(staminaHolder)
	end

	local offset = activeOffsetAttr and character:GetAttribute(activeOffsetAttr) or nil
	local shootEnabled = shootGetter()
	if releaseGetter() and activeOffsetAttr then
		updateAutoTime(character, now, offset, shootEnabled)
	elseif pressTime then
		releaseShoot()
		pressTime = nil
	end

	if now - statusClock >= 0.15 then
		statusClock = now
		offsetLabel.Text = "Offset: " .. (typeof(offset) == "number" and string.format("%.3f", offset) or "--")

		local action = character:GetAttribute("Action")
		if action ~= lastAction then
			lastAction = action
			print("[Azure Hub] action -> " .. tostring(action))
		end
		actionLabel.Text = "Action: " .. tostring(action or "--")
		metaLabel.Text = string.format("Meta %.4f%s | Tiros %d",
			getTarget(), targetOverride and "*" or "", shotCount)

		-- O que o jogo registrou no release: calibracao fina.
		local releasedShot = character:GetAttribute("ReleasedShot")
		if releasedShot ~= lastReleasedShot then
			lastReleasedShot = releasedShot
			print(string.format("[Azure Hub] ReleasedShot -> %s | offset=%s",
				tostring(releasedShot),
				typeof(offset) == "number" and string.format("%.4f", offset) or "--"))
		end
		local meterIndex = character:GetAttribute("MeterIndex")
		if meterIndex ~= lastMeterIndex then
			lastMeterIndex = meterIndex
			print("[Azure Hub] MeterIndex -> " .. tostring(meterIndex))
		end

		local moved = lastOffsetChange > 0 and now - lastOffsetChange <= 4
		diagLabel.Text = string.format("CH:OK | %s | MV:%s | ST:%s",
			activeOffsetAttr or "AT:--", moved and "OK" or "--", staminaHolder and "OK" or "--")
	end
end

-- Loop principal: tick de 0.01s, pcall em volta pra nunca morrer em silencio.
task.spawn(function()
	while loaded do
		task.wait(CONFIG.tickRate)
		local ok, err = pcall(tickBody, os.clock())
		if not ok and err ~= lastError then
			lastError = err
			warn("[Azure Hub] ERRO: " .. tostring(err))
			diagLabel.Text = "ERRO - veja o console"
		end
	end
end)

print("[Azure Hub] Basketball carregado - Insert abre o painel")