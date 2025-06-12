-- Services
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

-- Dependencies
local Promise = require(game:GetService("ReplicatedStorage"):WaitForChild("Packages"):WaitForChild("Promise"))

-- Config
local REPLAY_STEP_RATE = 0.2 -- seconds per frame (5Hz replay)

-- Replay system
local ReplaySystem = {}
ReplaySystem._replayData = nil
ReplaySystem._runningPromise = nil
ReplaySystem._isRunning = false
ReplaySystem._startTime = 0

ReplaySystem.Data = {
    PlayerLogStartTime = {}, -- { {UserId = Id, StartTime = time}, ... }  (IN DESCENDING ORDER) --
    ReplayDummys = {
        Reserve = {}, -- {Instance, ...} --
        InUse = {}-- {userId = Instance, ...} --
    },
    ActivePlayerReplays = {} -- { {UserId = id, CurrentFrame = #, CurrentBufferFrame = #}, ... }  |  StartFrame --
}


function ReplaySystem:_SetPlayerLogStartTime()
    local rawData = self._replayData
    local movementLogs = rawData.movementLog

    for userId, logs in pairs(movementLogs) do
        local firstLog = logs[1]
        table.insert(self.Data.PlayerLogStartTime, {UserId = userId, StartTime = firstLog.time} )
    end

    table.sort(self.Data.PlayerLogStartTime, function(a, b)
        return a.StartTime > b.StartTime
    end)
end


function ReplaySystem:_CreateReplayDummys()
    local dummyModel = game:GetService("ReplicatedStorage").Prefabs.ReplayDummy

    local joinLeaveLog = self._replayData.joinLeaveLog

    local function getMaxLoadedPlayers()
        local currentLoaded = 0
        local maxLoaded = 0

        for i = 1, #joinLeaveLog do
            local currentData = joinLeaveLog[i]
            local action = currentData.Status

            if action == "Joined" then
                currentLoaded += 1

                if currentLoaded > maxLoaded then
                    maxLoaded = currentData
                end
                continue
            end

            currentLoaded -= 1
        end

        return maxLoaded
    end

    local maxLoadedPlayers = getMaxLoadedPlayers()
    for _ = 1, maxLoadedPlayers do
        local toReserve = dummyModel:Clone()
        toReserve.Parent = game:GetService("ReplicatedStorage").Temp

        table.insert(self.Data.ReplayDummys.Reserve, toReserve)
    end
end


function ReplaySystem:LoadReplayData(saveName: string, jsonString)
    local saveFile = game:GetService("ReplicatedStorage").Shared.ReplayFiles:FindFirstChild(saveName)
    if not saveFile then warn("Replay file " .. saveName .. " not found!!!") return end

    saveFile = require(saveFile)

	self:Reset()
    self:_SetPlayerLogStartTime()
	self._replayData = HttpService:JSONDecode(saveFile)
end



function ReplaySystem:_GetInitialPlayers() : table -- { UserId, ... } | Gets first player's that are should be loaded into the game when the recording started.
    local replayStart = self._replayData._logStartTime
    local joinLeaveLog = self._replayData.joinLeaveLog

    local playersToLoad = {} -- {UID = time}

    for i = 1, #joinLeaveLog do
        local logContent = joinLeaveLog[i]
        local userId = logContent.UserId
        local status = logContent.Status
        local timeStamp = logContent.timeStamp

        local function removePlayer(uid)
            for index = 1, #playersToLoad do
                if playersToLoad[i] ~= uid then continue end
                table.remove(playersToLoad, index)
            end
        end

        if status == "Joined" then
            if timeStamp > replayStart then break end -- Player is ahead of log start, stopping loading

            table.insert(playersToLoad, userId)
        end

        if status ~= "Left" then error("Malformatted entry!") return end

        removePlayer(userId)
    end

    return playersToLoad
end


function ReplaySystem:_RemoveReplayCharacters()
    for _, char in pairs(self.Data.ReplayDummys.InUse) do
		char:Destroy()
	end
    self.Data.ReplayDummys.InUse = {}

    for _, char in pairs(self.Data.ReplayDummys.Reserve) do
		char:Destroy()
	end
    self.Data.ReplayDummys.Reserve = {}
end

function ReplaySystem:Reset()
	self:Stop()
	self:_RemoveReplayCharacters()
	self._startTime = 0
end

function ReplaySystem:Stop()
	self._isRunning = false
	if self._runningPromise then
		self._runningPromise:cancel()
		self._runningPromise = nil
	end
end

function ReplaySystem:Start()
	if not self._replayData then return end
	self._isRunning = true

    self:_CreateReplayDummys()

    local initalCharacters = self:_GetInitialPlayers()

    local function SetStartPlayerFirstFrame(plrList) -- {UserId = startFrameTime, ...} Sets all userIds in list as key, then sets value as 1. (1st frame already complete)
        local newList = {}
        for _, userId in pairs(plrList) do
            local data = {UserId = userId, CurrentFrame = 1, _CurrentBufferFrame = 1}
            table.insert(newList, data)
        end

        -- {UserId = id, CurrentFrame = #, CurrentBufferFrame = #} --
        self.Data.ActivePlayerReplays = newList
    end

    local function RemoveStartPlayersFromNextStartList() -- Removes the starter player's from the nextStartTime list to prevent two copies of the starter characters
        local totalRemoved = 0
        local toBeRemoved = initalCharacters
        for index = 1, #self.Data.PlayerLogStartTime do -- Loops through Start Times
            local currentData = self.Data.PlayerLogStartTime[index]

            for removeIndex, userId in pairs(toBeRemoved) do -- Loops through list to remove from start times
                if currentData.UserId ~= userId then continue end -- Skip if name does not match
                table.remove(self.Data.PlayerLogStartTime, index)
                table.remove(toBeRemoved, removeIndex) -- Remove from BOTH lists
                break
            end

            if #toBeRemoved == 0 then -- If all are removed, break from the function
                return
            end
        end
    end

    local function initalizeStartingPlayerPositions() -- Renders the first frame of the start players position log.
        for _, userId in pairs(initalCharacters) do
            local dummy = table.remove(self.Data.ReplayDummys.Reserve, 1)
            local pos: Vector3 = self._replayData.movementLog[userId].hrpPosition
            local rot: Vector3 = self._replayData.movementLog[userId].hrpRotation

            local newCFrame = CFrame.new(pos) * CFrame.Angles(math.rad(rot.X), math.rad(rot.Y), math.rad(rot.Z))

            dummy:PivotTo(newCFrame)
            dummy.Parent = workspace.ReplayFolder
        end
    end

    SetStartPlayerFirstFrame(initalCharacters) -- Loads Data for start players on Current Loaded List 
    initalizeStartingPlayerPositions() -- Render first characters
    RemoveStartPlayersFromNextStartList() -- Stop first characters rendering twice

    -- Frame alignment --
    -- If frame is within tolerance (5% of frame length), snap it to time.  |  Replay Time = 1.2, Frame Time = 1.204 -> New Frame Time = 1.204
    -- FrameLag > tolerance (5%) & inside 1 frame -> (lateFrameTime-replayClock)/(nextFrameTime - currentFrameTime) = InterpolationTime
    -- FrameLag > tolerance (5%) & outside 1 frame -> Set replayClock to frame time + set position with no tween

    local function NewReplayPromise(_____self)
        return Promise.new(function(resolve, reject, onCancel)
            local enabled = true
            local sampleRate = 5

            local CurrentFrameTime = self._replayData._logStartTime

            local startTimes = self.Data.PlayerLogStartTime -- uid = st --
            local nextStartTime = startTimes[1].StartTime

            --self.Data.ActivePlayerReplays -- { userId = currentFrame } --

            local function CheckForNewStart() : boolean -- Returs true if the next start time is now.
                if CurrentFrameTime < nextStartTime then return end

                print("Start next player!")
                return true
            end

            local function RenderNewFrames()
                local activeReplays = self.Data.ActivePlayerReplays

                for _, data in pairs(activeReplays) do
                    local userId = data.UserId
                    local currentFrame = data.CurrentFrame
                    local frameData = self._replayData.movementLog[userId]
                    local totalFrames = #frameData

                    local isLastFrame = totalFrames == currentFrame

                    if isLastFrame then
                        print("Do something to end it")
                    end

                    local nextFrameData = frameData[currentFrame+1]

                    data.CurrentFrame = currentFrame + 1
                end
            end


            local self_data = {
                PlayerLogStartTime = {}, -- { {UserId = Id, StartTime = time}, ... }  (IN DESCENDING ORDER) --
                ReplayDummys = {
                    Reserve = {}, -- {Instance, ...} --
                    InUse = {}-- {userId = Instance, ...} --
                },
                ActivePlayerReplays = {} -- { {UserId = id, CurrentFrame = #, CurrentBufferFrame = #}, ... }  |  StartFrame --
            }



            while enabled do
                CheckForNewStart()

                task.wait(1/sampleRate)
            end


        end)
    end


    -- Use a Promise to make a loop that renders a frame based off an interval variable --

    -- Use PlayerLogStartTime to detect when a new player should start playing --


	-- Get earliest movement timestamp
	local minTime = math.huge
	for _, logs in pairs(self._replayData.movementLog) do
		if logs[1] and logs[1].time < minTime then
			minTime = logs[1].time
		end
	end
	self._startTime = minTime

	-- Spawn characters
	for userId, logs in pairs(self._replayData.movementLog) do
		local char = Instance.new("Model")
		char.Name = "Replay_" .. tostring(userId)
		local hrp = Instance.new("Part")
		hrp.Name = "HumanoidRootPart"
		hrp.Size = Vector3.new(2, 2, 1)
		hrp.Anchored = true
		hrp.Parent = char
		local hum = Instance.new("Humanoid")
		hum.Parent = char
		char.Parent = workspace
		self.Data.ReplayDummys[userId] = { Character = char, Log = logs, Index = 1 }
	end

	-- Start replay loop
	self._runningPromise = Promise.new(function(resolve, reject, onCancel)
		onCancel(function()
			self._isRunning = false
		end)

		local startTime = os.clock()
		while self._isRunning do
			local currentTime = os.clock() - startTime + self._startTime

			for userId, data in pairs(self.Data.ReplayDummys) do
				local log = data.Log
				while log[data.Index + 1] and log[data.Index + 1].time <= currentTime do
					data.Index += 1
				end

				local entry = log[data.Index]
				if entry then
					local pos = Vector3.new(unpack(entry.hrpPosition))
					local rot = Vector3.new(unpack(entry.hrpRotation))
					local cf = CFrame.new(pos) * CFrame.Angles(math.rad(rot.X), math.rad(rot.Y), math.rad(rot.Z))
					data.Character.HumanoidRootPart.CFrame = cf
				end
			end

			task.wait(REPLAY_STEP_RATE)
		end
		resolve()
	end)
end

function ReplaySystem:SwitchReplay(newJsonString)
	self:LoadReplayData(newJsonString)
	self:Start()
end

return ReplaySystem
