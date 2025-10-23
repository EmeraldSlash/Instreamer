--
-- Server
--

local Asset_ById = {}
for _, Asset in game.ServerStorage.Assets:GetChildren() do
	Asset_ById[Asset.Name] = Asset
end

Instreamer.ServerInit(function(Player, AssetId, Mode)
	local Asset = nil
	local DestroyAfterSend = false
	
	-- If the asset is being streamed in at the server's request.
	if Mode == "server" then
		Asset = Asset_ById[AssetId]
		
	-- Otherwise, this is a request from a client. Here we only allow clients to 
	-- request a Ground asset.
	elseif AssetId == "Ground" then
		local Model = Instance.new("Model")
		Model.Name = "Ground"
		local Part = Instance.new("Part")
		Part.Parent = Model
		Part.Anchored = true
		Part.Size = Vector3.new(100, 1, 100)
		Part.Position = Vector3.new(0, 0.5, 0)
		Model.PrimaryPart = Part
		
		Asset = Model
		DestroyAfterSend = true
	end
	
	return Asset, DestroyAfterSend
end)

game.Players.PlayerAdded:Connect(function(Player)
	local Mandate = Instreamer.ServerMandate(Player, "Wall")
	
	-- Release the mandate when player leaves the game.
	Player.AncestryChanged:Connect(function(_, Parent)
		if not Parent then
			
			Mandate:Release()
		end
	end)
end)

--
-- Client
--

Instreamer.ClientInit()

-- Immediate-mode example

local WallsVisible = true -- imagine this gets turned on and off somewhere
local Walls: {Model} = {}
local Ground = nil

game:GetService("RunService").Heartbeat:Connect(function()
	
	-- Load the wall models that the server decides to stream in.
	if not WallsVisible then
		for _, Wall in Walls do
			Wall:Destroy()
		end
		table.clear(Walls)
	else
		local WallTemplate = Instreamer.ClientUse("server", "Wall")
		if WallTemplate and not Walls[1] then
			for Index = 1, 4 do
				local Wall = WallTemplate:Clone() :: Model
				Wall.Parent = workspace
				Wall:PivotTo(CFrame.new(100*Index, 0, 0))
				Walls[#Walls+1] = Wall
			end
		end
	end
	
	-- Load the ground model that the client requests from the server.
	if not Ground then
		local GroundTemplate = Instreamer.ClientUse("client", "Ground")
		if GroundTemplate then
			local New = GroundTemplate:Clone()
			New.Parent = workspace
			Ground = New
		end
	end
end)

--[[
-- Retained-mode example

type WallRecord = {
	Wall: Model?;
	Sub: Instreamer.ClientSub;
}
local function CreateWall(AtCFrame)
	local WallRecord = {}
	WallRecord.Sub = Instreamer.ClientSubscribe("client", "Wall")
	WallRecord.Sub:OnLoadedOnce(function(WallTemplate)
		local Wall = WallTemplate:Clone() :: Model
		Wall.Parent = workspace
		Wall:PivotTo(AtCFrame)
		WallRecord.Wall = Wall
	end)
	return WallRecord
end
local function DestroyWall(WallRecord)
	WallRecord.Sub:Unsubscribe()
	if WallRecord.Wall then
		WallRecord.Wall:Destroy()
	end
end
--]]