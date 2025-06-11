local Promise = require(game:GetService("ReplicatedStorage"):WaitForChild("Packages"):WaitForChild("Promise"))

local mainFrame = game.Players.LocalPlayer.PlayerGui:WaitForChild("ReplayCapture"):WaitForChild("Content")

local startStopLabel: TextLabel = mainFrame:WaitForChild("StartStopLabel")
local frameCountLabel: TextLabel = mainFrame:WaitForChild("FrameLabel"):WaitForChild("FrameCount")
local startStopButton: TextButton = startStopLabel:WaitForChild("Button")

local replayRemote: RemoteEvent = game:GetService("ReplicatedStorage"):WaitForChild("Remotes"):WaitForChild("Other"):WaitForChild("ReplayCapture")

local capturePromise = nil
local playerCount = #game.Players:GetChildren()
local enabled = false

local frameCount = 0

local function newCapturePromise()
    return Promise.new(function(_, _, onCancel)
        local go = true
        local rate = 5

        onCancel(function()
            go = false
            capturePromise = nil
            frameCount = 0
        end)

        frameCountLabel.Text = "0"

        while go do
            task.wait(1/rate)
            frameCount += 1*playerCount

            frameCountLabel.Text = tostring(frameCount)
        end
    end)
end

local function handleStartStopButton()
    enabled = not enabled

    if not enabled then
        print("Stopping Capture!")
        replayRemote:FireServer(false)
        capturePromise:cancel()
        startStopButton.BackgroundColor3 = Color3.fromRGB(165, 255, 92)
        startStopLabel.Text = "Start Capture"

        return
    end

    print("Starting Capture!")
    replayRemote:FireServer(true)
    startStopButton.BackgroundColor3 = Color3.fromRGB(255, 79, 79)
    startStopLabel.Text = "Stop Capture"
    capturePromise = newCapturePromise()

end


game.Players.Changed:Connect(function(property)
    local newPlayerCount = #game.Players:GetChildren()

    playerCount = newPlayerCount
end)


startStopButton.MouseButton1Click:Connect(handleStartStopButton)