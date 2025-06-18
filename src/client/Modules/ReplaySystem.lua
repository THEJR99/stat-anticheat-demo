-- Services
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local RS = game:GetService("RunService")
local TS = game:GetService("TweenService")

-- Dependencies
local Promise = require(game:GetService("ReplicatedStorage"):WaitForChild("Packages"):WaitForChild("Promise"))

-- Config
local REPLAY_STEP_RATE = 0.2 -- seconds per frame (5Hz replay)

-- Replay system
local ReplaySystem = {}
ReplaySystem._importedData = nil
ReplaySystem._replayPromise = nil
ReplaySystem._isRunning = false
ReplaySystem._startTime = 0

ReplaySystem.Data = {
    PlayerLogStartTime = {}, -- { {UserId = Id, StartTime = time}, ... }  (IN DESCENDING ORDER) --
    PlayerLogStopTime = {}, -- { {UserId = Id, EndTime = time}, ... }  (IN DESCENDING ORDER) --
    ReplayDummys = {
        Reserve = {}, -- {Instance, ...} --
        InUse = {}-- {userId = Instance, ...} --
    },
    ActivePlayerReplays = {}, -- { {UserId = id, CurrentFrame = #, CurrentBufferFrame = #}, ... }  |  StartFrame --
    NameList = {}, -- { UserId = PlayerName }


    _ReplayData = {}, -- { { time = t, {userid = {pos, rot}, ...} } }
    _ReplayCacheData = { CurrentPosition = 0, FrameData = {} }, -- FrameData = { {time = t, playerLogs = { userId = {hrpPosition = Vector3(), hrpRotation = Vector3()}, ... } } }
    _ReplayCacheSize = 50, -- Caches x frames left and right.  |  50 - TimePos - 50
    ReplayClock = 0,
}



function ReplaySystem:_InitializeReplayDummys() -- Makes all dummys needed and sends to reserve. In use are labeled by {UserId = Instance}.
    local dummyModel = game:GetService("ReplicatedStorage").Prefabs.ReplayDummy

    local joinLeaveLog = self._importedData.joinLeaveLog

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


function ReplaySystem:_SetStartStopTimes()
    for userId, logs in pairs(self._importedData.movementLog) do
        self.Data.PlayerLogStartTime[userId] = logs[1].time
        self.Data.PlayerLogStopTime[userId] = logs[#logs].time
    end
end


function ReplaySystem:LoadReplayData(saveName: string, jsonString)
    local saveFile = game:GetService("ReplicatedStorage").Shared.ReplayFiles:FindFirstChild(saveName)
    if not saveFile then warn("Replay file " .. saveName .. " not found!!!") return end

    saveFile = require(saveFile)

	self:Reset()
    self:_SetStartStopTimes()
	self._importedData = HttpService:JSONDecode(saveFile)
end



function ReplaySystem:_GetInitialPlayers() : table -- { UserId, ... } | Gets first player's that are should be loaded into the game when the recording started.
    local replayStart = self._importedData._logStartTime
    local joinLeaveLog = self._importedData.joinLeaveLog

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
	if self._replayPromise then
		self._replayPromise:cancel()
		self._replayPromise = nil
	end
end

function ReplaySystem:_PlayReplay()
    local sampleRate = 5
    local frameSlipTolerance = .1 -- Out of 1 --
    local playbackDirection = 1
    local playbackSpeed = 1
    local calculatedPlaybackSpeed = (1/sampleRate)*playbackSpeed
    local startTime = self._importedData._logStartTime

    RS:BindToRenderStep("ReplaySystem", Enum.RenderPriority.Camera-1, function(deltaTime)

        local function setPlayerPositions(targetTime) -- Sets replay dummy's cframes (getInterpolatedCFrames) --
            local timeFromStart = targetTime - startTime
            local framesBetweenEstimate = math.floor(timeFromStart/(1/sampleRate))

            local function findFrame(frameNumber: number) : number
                local goBackFrames = self._importedData.movementLog[frameNumber] > targetTime
                local goForwardFrames = self._importedData.movementLog[frameNumber] < targetTime
                local isCorrectFrame = (not goBackFrames) and (not goForwardFrames)

                if isCorrectFrame then
                    return frameNumber
                end

                if goBackFrames then
                    return findFrame(frameNumber-1)

                elseif goForwardFrames then
                    return findFrame(frameNumber+1)
                end

                error("should not have reached this part of execution!")
            end

            local function getDummy(_UserId) : Model
                    local dummyFromInUse = self.Data.ReplayDummys.InUse[_UserId]
                    if dummyFromInUse then return dummyFromInUse end

                    local replayDummy = table.remove(self.Data.ReplayDummys.Reserve, 1)
                    self.Data.ReplayDummys[_UserId] = replayDummy
                    replayDummy.Parent = game.Workspace.ReplayFolder

                    return replayDummy
            end

            local function checkForUnusedDummys(_userIdList)
                for userId, dummy in pairs(self.Data.ReplayDummys.InUse) do
                    if _userIdList[userId] then return end

                    dummy.NameTag.TextLabel.Text = ""
                    dummy.Parent = game:GetService("ReplicatedStorage").Temp
                    table.insert(self.Data.ReplayDummys.Reserve, dummy)
                    self.Data.ReplayDummys.InUse[userId] = nil
                end
            end

            local function updateUI(currentFrameNumber, currentReplayDuration)
                local mainFrame = game.Players.LocalPlayer.PlayerGui.ReplayDisplay.logContent
                local timeText = mainFrame.TimeLabel
                local frameText = mainFrame.FrameLabel

                timeText.Text = tostring(currentReplayDuration)
                frameText.text = tostring(currentFrameNumber)
            end

            local frameNumber = findFrame(framesBetweenEstimate)
            local userIdList = {} -- For checking if any dummys are not in use now --

            local frameA = self._importedData.movementLog[frameNumber]
            local frameB = self._importedData.movementLog[frameNumber+1]

            local frameTimeA = frameA.time
            local frameTimeB = frameB.time

            local replayClockTime = self.Data.ReplayClock
            local frameDrift = (frameTimeB.time - frameTimeA.time) - (sampleRate)
            local isWithinFrameTolerance =  frameDrift <= (sampleRate * frameSlipTolerance)
            local outsideToleranceInFrame = frameDrift <= sampleRate

            local movement = deltaTime * playbackSpeed * playbackDirection
            local alpha

            if isWithinFrameTolerance then
                alpha = (replayClockTime - frameTimeA + movement) / (frameTimeB.time - frameTimeA.time)

            elseif outsideToleranceInFrame then
                alpha = (replayClockTime - frameTimeA + movement) / (frameTimeB.time - frameTimeA.time)
                print("Frame misalignment!")
            else -- Is out of sync by a frame or more

            end

            for userId, data in pairs(frameA) do
                if userId == 'time' then continue end
                local posA = Vector3.new(data["hrpPosition"][1], data["hrpPosition"][2], data["hrpPosition"][3])
                local rotA = Vector3.new( math.rad(data["hrpRotation"][1]), math.rad(data["hrpRotation"][2]), math.rad(data["hrpRotation"][3]) )

                local dataB = frameB[userId]
                local posB = Vector3.new(dataB["hrpPosition"][1], dataB["hrpPosition"][2], dataB["hrpPosition"][3])
                local rotB = Vector3.new( math.rad(dataB["hrpPosition"][1]), math.rad(dataB["hrpPosition"][2]), math.rad(dataB["hrpPosition"][3]))

                local newPosition = posA:Lerp(posB, alpha)
                local newRotation = rotA:Lerp(rotB, alpha)

                local newCFrame = CFrame.new(newPosition) * CFrame.Angles(newRotation.X, newRotation.Y, newRotation.Z)

                -- Check if replay dummys are in replay, if not - insert and position them --

                userIdList[userId] = true
                local ReplayDummy = getDummy(userId)
                ReplayDummy:PivotTo(newCFrame)
            end

            checkForUnusedDummys(userIdList)

            updateUI(frameNumber, timeFromStart)
            self.Data.ReplayClock = frameTimeA + alpha * (frameTimeB - frameTimeA)
        end

        setPlayerPositions(self.Data.ReplayClock)
    end)
end

function ReplaySystem:_PauseReplay()
    RS:UnbindFromRenderStep("ReplaySystem")
end

function ReplaySystem:Start()
	if not self._importedData then return end
	self._isRunning = true

    self:_InitializeReplayDummys()

    local initalCharacters = self:_GetInitialPlayers()


    local function SetNewCharacterPosition(character: Model, Position: table, Rotation: table, Time: number)
        local pos = Vector3.new(Position[1], Position[2], Position[3])
        local rot = Vector3.new(math.rad(Rotation[1]), math.rad(Rotation[2]), math.rad(Rotation[3]))

        local newCFrame = CFrame.new(pos) * CFrame.Angles(rot)

        local function TweenPivotTo(Model: Model, TargetCFrame: CFrame, _Time: number)
            return Promise.new(function(resolve, _, cancel)
                local tempCFrame = Instance.new('CFrameValue')
                tempCFrame.Value = Model:GetPivot()

                TS:Create(tempCFrame, TweenInfo.new(Time), {Value = TargetCFrame}):Play()

                local connection = tempCFrame.Changed:Connect(function(value)
                    Model:PivotTo(value)
                end)

                task.wait(Time)
                connection:Disconnect()
                tempCFrame:Destroy()
                resolve()
            end)
        end

        if not Time then
            character:PivotTo(newCFrame)
            return
        end

        TweenPivotTo(character, newCFrame, Time)
    end

    local function LoadInPlayer(UserId) -- Used when player's data and replay dummy when their data should start (Joining) --
        local data = {UserId = UserId, CurrentFrame = 1, _CurrentBufferFrame = 1}
        table.insert(self.Data.ActivePlayerReplays, data) -- Set data --

        local newDummy = self.Data.ReplayDummys.Reserve[1]

        self.Data.ReplayDummys.InUse[UserId] = newDummy
        newDummy.NameTag.TextLabel.Text = "Loading Name.."
        newDummy.Parent = workspace.ReplayFolder

        Promise.try(function() -- Tries to get name then set it to Dummy's name tag.
            local playerName = "Could Not Get Player Name."
            local retries = 0
            local maxRetries = 5

            while retries <= maxRetries do
                local success, result = pcall(function()
                    return Players:GetNameFromUserIdAsync(UserId)
                end)

                if success then
                    newDummy.NameTag.TextLabel.Text = result
                end

                print(result)
                retries += 1

                if retries <= maxRetries then
                    task.wait(1)
                end
            end
        end)

        local firstFrameReplayData = self._importedData.movementLog[UserId][1]
        local firstPos = firstFrameReplayData.hrpPosition
        local firstRot = firstFrameReplayData.hrpRotation
        SetNewCharacterPosition(newDummy, firstPos, firstRot)
    end

    local function LoadInStarterPlayerData(plrList) -- Loads starter player's logs + dummy
        for _, userId in pairs(plrList) do
            LoadInPlayer(userId)
        end
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
            local pos: Vector3 = self._importedData.movementLog[userId].hrpPosition
            local rot: Vector3 = self._importedData.movementLog[userId].hrpRotation

            local newCFrame = CFrame.new(pos) * CFrame.Angles(math.rad(rot.X), math.rad(rot.Y), math.rad(rot.Z))

            dummy:PivotTo(newCFrame)
            dummy.Parent = workspace.ReplayFolder
        end
    end

    LoadInStarterPlayerData()
    initalizeStartingPlayerPositions() -- Render first characters
    RemoveStartPlayersFromNextStartList() -- Stop first characters rendering twice


    local function NewReplayPromise(_____self)
        return Promise.new(function(resolve, reject, onCancel)
            local enabled = true
            local sampleRate = 5
            local ReplayClockTime = self._importedData._logStartTime

            local startTimes = self.Data.PlayerLogStartTime -- uid = st --
            local nextStartTime = startTimes[1].StartTime
            local frameSlipTolerance = 10 -- In Percent --

            --self.Data.ActivePlayerReplays -- { userId = currentFrame } --

            local function CheckForNewStart() : boolean -- Returs true if the next start time (Player joining replay) is now.
                if ReplayClockTime < nextStartTime then return end

                print("Start next player!")
                return true
            end



            local function RenderNewFrames()
                local activeReplays = self.Data.ActivePlayerReplays
                local computedSampleRate = 1/sampleRate

                for index, metaData in pairs(activeReplays) do
                    local userId = metaData.UserId
                    local currentFrame = metaData.CurrentFrame
                    local frameData = self._importedData.movementLog[userId]
                    local totalFrames = #frameData

                    local isLastFrame = totalFrames == currentFrame

                    if isLastFrame then
                        print("Do something to end it")
                        -- PLAYER LEFT GAME --
                    end

                    local nextFrameData = frameData[currentFrame+1] -- {time, pos, rot} --
                    local replayMetaData = self.Data.ActivePlayerReplays -- {id, currFrame, buffFrame} --
                    local replayDummy = self.Data.ReplayDummys.InUse[userId]

                    local nextFrameTimeOffset = nextFrameData.time - ReplayClockTime -- (frameTime - clockTime) | Ideally, should be 1/sampleRate
                    local nextFrameTimeDrift = nextFrameTimeOffset - (1/sampleRate)
                    local frameDriftPercent = nextFrameTimeDrift / (1/sampleRate)

                    print("Frame time offset: " .. nextFrameTimeOffset)
                    print("Frame time drift: " .. nextFrameTimeDrift)
                    print("Frame drift percentage: " .. frameDriftPercent)

                    local isWithinTolerance = (1/frameSlipTolerance) >= frameDriftPercent
                    local isWithinFrame = nextFrameTimeDrift < (1/sampleRate)
                    local isNotWithinFrame = (not isWithinFrame and not isWithinFrame)
                    local frameAdjusted = false

                    local newPosition = nextFrameData.hrpPosition
                    local newRotation = nextFrameData.hrpRotation

                    if isWithinTolerance then -- Sets position with smooth tween
                        print("Within tolerance")
                        SetNewCharacterPosition(replayDummy, newPosition, newRotation, computedSampleRate)

                        frameAdjusted = true
                    end

                    if isWithinFrame then -- Sets position with faster tween
                        if frameAdjusted then continue end


                    end

                    if isNotWithinFrame then -- Set position immediately with no tween
                        if frameAdjusted then continue end

                        SetNewCharacterPosition(replayDummy, newPosition, newRotation)
                        frameAdjusted = true
                    end

                    self.Data.ActivePlayerReplays[index].CurrentFrame = currentFrame + 1 -- Sets frame to next frame
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

                RenderNewFrames()

                task.wait(1/sampleRate)
            end


        end)
    end

	self._replayPromise = NewReplayPromise(self)
end

function ReplaySystem:SwitchReplay(newJsonString)
	self:LoadReplayData(newJsonString)
	self:Start()
end

return ReplaySystem
