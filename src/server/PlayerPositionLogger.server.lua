local Promise = require(game:GetService("ReplicatedStorage"):WaitForChild("Packages"):WaitForChild("Promise"))

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

-- SETTINGS
local SAMPLE_INTERVAL_PER_SECOND = 1 -- How often to sample HRP data (in seconds)

local sampleSize = 60

-- SERVER METADATA
local serverSession = {
    logVersion = 0.01,
    serverId = game.JobId,
    sessionStartTime = os.time(), -- epoch timestamp
    joinLeaveLog = {},            -- array of { userId = number, time = os.time(), action = "join"/"leave" }
    movementLog = {}              -- [userId] = { { time = t, hrpPosition = Vector3, hrpRotation = Vector3 }, ... }
}

-- JOIN/LEAVE TRACKING
Players.PlayerAdded:Connect(function(player)
    table.insert(serverSession.joinLeaveLog, {
        userId = player.UserId,
        time = time(),
        action = "join"
    })

    serverSession.movementLog[player.UserId] = {}
end)

Players.PlayerRemoving:Connect(function(player)
    table.insert(serverSession.joinLeaveLog, {
        userId = player.UserId,
        time = time(),
        action = "leave"
    })
end)

-- MOVEMENT TRACKING

Promise.new(function(resolve)
    local enabled = true

    while enabled do
        if sampleSize == 60 then
            enabled = false
        end

        for _, player in pairs(Players:GetPlayers()) do
            local character = player.Character
            local hrp = character and character:FindFirstChild("HumanoidRootPart")
            if not hrp then continue end

            table.insert(serverSession.movementLog[player.UserId], {
                time = time(),
                hrpPosition = hrp.Position,
                hrpRotation = hrp.Orientation
            })
        end

        sampleSize += 1
        task.wait(1/SAMPLE_INTERVAL_PER_SECOND)
    end

    resolve()
end)

