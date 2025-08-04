--
-- Server
--

local Asset_ById = {}
for _, Asset in game.ServerStorage.Assets:GetChildren() do
	Asset_ById[Asset.Name] = Asset
end

Instreamer.ServerInit(function(Player, AssetId)
	return Asset_ById[AssetId]
end)

--
-- Client
--

Instreamer.ClientInit()

-- Immediate-mode example

local WallsVisible = false -- maybe this gets turned on and off somewhere
local Walls = {}

game:GetService("RunService").Heartbeat:Connect(function()
	if not WallsVisible then
		for _, Wall in Walls do
			Wall:Destroy()
		end
		table.clear(Walls)
	else
		local WallTemplate = Instreamer.ClientUse("Wall")
		if not Walls[1] then
			for Index = 1, 4 do
				local Wall = WallTemplate:Clone()
				Wall.Parent = workspace
				Wall:PivotTo(CFrame.new(100*Index, 0, 0))
				Walls[#Walls+1] = Wall
			end
		end
	end
end)

-- Retained-mode example

type WallRecord = {
	Wall: Model?;
	Sub: Instreamer.ClientSub;
}
local function CreateWall(AtCFrame)
	local WallRecord = {}
	WallRecord.Sub = Instreamer.ClientSubscribe("Wall")
	WallRecord.Sub:OnLoaded(function(WallTemplate)
		local Wall = WallTemplate:Clone()
		Wall.Parent = workspace
		Wall:PivotTo(AtCFrame)
		WallRecord.Wall = Wall
		-- If we wanted to could also unsubscribe here.
	end)
	return WallRecord
end
local function DestroyWall(WallRecord)
	WallRecord.Sub:Unsubscribe()
	if WallRecord.Wall then
		WallRecord.Wall:Destroy()
	end
end
