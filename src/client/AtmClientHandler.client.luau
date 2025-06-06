-- LocalScript for Minigame (Put in StarterPlayerScripts or via ReplicatedStorage clone)
-- UI Setup & Logic
-- Add a ScreenGui named "HackUI" under ReplicatedStorage with a Frame named "MinigameFrame"
-- Inside MinigameFrame, add:
-- - a Frame named "TargetZone" (where the button must be clicked)
-- - a Frame named "Slider" (animated left to right)
-- - a TextLabel named "StatusLabel"

-- LocalScript: HackGameClient
local RS = game:GetService("ReplicatedStorage")
local CAS = game:GetService("ContextActionService")

local Promise = require(game:GetService("ReplicatedStorage"):WaitForChild("Packages"):WaitForChild("Promise"))

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local player = Players.LocalPlayer
local HackUiInstance = RS:WaitForChild("UIObjects"):WaitForChild("HackUI")
local HackEvent = RS:WaitForChild("Remotes"):WaitForChild("ATM"):WaitForChild("StartATMMinigame")

local HackUI = HackUiInstance:Clone()
local frame: Frame = HackUI:WaitForChild("MinigameFrame")
local slider: Frame = frame:WaitForChild("Slider")
local targetZone: Frame = frame:WaitForChild("TargetZone")
local status = frame:WaitForChild("Status")

local popsNeeded = 3
local popsCompleted = 0
local direction = 1
local speed = 1
local running = false
local atm = nil

local DistancePromise = nil

function resetGame()
    print("resetting pos")
	popsCompleted = 0
	slider.Position = UDim2.fromScale(0, slider.Position.Y.Scale)
	moveSuccessArea()
    running = true
end

function endGame()
    popsCompleted = 0
    running = false
    RunService:UnbindFromRenderStep("HackATM")
    CAS:UnbindAction("AtmHackClick")
    if DistancePromise then DistancePromise:cancel() end
    HackUI:Destroy()
end

function moveSuccessArea()
    local successRange = 1-frame.Size.X.Scale
    local selectedValue = (math.random(0, 100) / 100) * successRange

    targetZone.Position = UDim2.fromScale(selectedValue, 0)
end

function CreateDistanceCheckPromise()
    return Promise.new(function(resolve, reject, onCancel)
        local enabled = true
        local rangeToHack = 7.5
        local player = game.Players.LocalPlayer

        local function stopped()
            enabled = false
            endGame()
        end

        onCancel(stopped)

        while enabled do
            task.wait(1/10)

            local char = player.Character
            if not char then continue end

            local hrp = char.HumanoidRootPart
            if not hrp then continue end

            local hrpPosition = hrp.Position
            local atmPosition = atm.Position
            local distance = (hrpPosition - atmPosition).Magnitude

            if distance > rangeToHack then stopped() end
        end
    end)
end

function updateSlider(dt)
	if not running then return end

    local maxRight = 1-slider.Size.X.Scale
    local newSliderPosition = slider.Position.X.Scale + dt * speed * direction

    if newSliderPosition <= 0 then
        newSliderPosition = UDim2.fromScale(0, 0)
        direction = 1
        return
    end

    if newSliderPosition >= maxRight then
        direction = -1
        newSliderPosition = UDim2.fromScale(maxRight, 0)
        return
    end

	slider.Position =  UDim2.fromScale(newSliderPosition, 0)
end

function checkPop()
    local sliderPosition = slider.Position.X.Scale
    local extendRange = targetZone.Size.X.Scale/2
    local successAreaMaxEndRange = 1-targetZone.Size.X.Scale
    local endOfSuccessArea = math.clamp(( (targetZone.Position.X.Scale + slider.Size.X.Scale) + extendRange ), 0, successAreaMaxEndRange)

    local startOfSucessArea = math.clamp(targetZone.Position.X.Scale - extendRange, 0, successAreaMaxEndRange)

    print("Start: " .. tostring(startOfSucessArea) .. " | End: " .. tostring(endOfSuccessArea))
    print(sliderPosition)

    local sucessfulPop = (sliderPosition >= startOfSucessArea) and (sliderPosition <= endOfSuccessArea)

    if sucessfulPop then
        popsCompleted += 1
        status.Text = "Pop! (" .. popsCompleted .. "/3)"

        local threePopsCompleted = popsCompleted >= popsNeeded
		if threePopsCompleted then
			status.Text = "Success!"
			running = false
			endGame()
            return
		end

        moveSuccessArea()

        return
    end

    warn("YOU\'RE A FAILURE!!!")
    status.Text = "Hacking..."
    popsCompleted = 0
	moveSuccessArea()
end

function HackingClickHandler(_, inputState, _)
    if inputState ~= Enum.UserInputState.Begin then return end

    checkPop()
end

function StartProceedure(atmObject)
    print("Starting")
    if running then return end

    HackUI = HackUiInstance:Clone()
    frame = HackUI:WaitForChild("MinigameFrame")
    slider = frame:WaitForChild("Slider")
    targetZone = frame:WaitForChild("TargetZone")
    status = frame:WaitForChild("Status")

    atm = atmObject
    HackUI.Parent = player.PlayerGui
	resetGame()

    DistancePromise = CreateDistanceCheckPromise()
    RunService:BindToRenderStep("HackATM", 1000, updateSlider)
    CAS:BindAction("AtmHackClick", HackingClickHandler, false, Enum.UserInputType.MouseButton1)
end



--#region Set Up ATMs
repeat task.wait(1) until game:IsLoaded()
local atms = workspace:WaitForChild("Atms"):GetChildren()

for _, atmObject in pairs(atms) do
    local prompt = atmObject.ProximityPrompt

    prompt.Triggered:Connect(function()
        StartProceedure(atmObject)
    end)
end


--#endregion