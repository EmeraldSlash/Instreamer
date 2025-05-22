--!strict

-- Instreamer: Per-player instance streaming.
--
-- https://github.com/EmeraldSlash/Instreamer
--
-- Created by Rio Manson-Hay (@EmeraldSlash)
--
-- Version: 1 (2025-05-22)
--
-- Change Log:
--
-- Version 1: Initial version.

---
-- Shared API Summary:
--
-- .IdFromStrings(): string
-- .StringsFromId(): {string}
-- .RequestId: enum
-- type AssetRequest
-- type AssetResponse

--
-- Server API Summary:
--
-- .MakeAssetResponse(): AssetResponse
-- type Replicator
-- .CreateReplicator(): Replicator
-- type AssetSender
-- .AS_Create(): AssetSender
-- .AS_Send()
-- .AS_Finish()

--
-- Client API Summary:
--
-- type AssetHandle
-- type AssetIncomplete
-- type AssetLoadedCallback
-- .AH_AddCallback()
-- .AH_RemoveCallback()
-- .AH_AddThread()
-- .AH_RemoveThread()
-- .AH_YieldUntilReady()
-- type StreamerClient
-- .SC_Create(): StreamerClient
-- .SC_ReceiveAssets()
-- .SC_CheckAssets()
-- .SC_CleanupAssets()
-- .SC_Use(): Instance?
-- .SC_Subscribe(): AssetHandle
-- .SC_Unsubscribe()

local Module = {}

-- Enable/disable microprofiler labels.
local PRF_ON = false

--
-- Internal utilities
--

-- Doubly Linked List
type DLL_Node<T> = T & {
	DLL_Sentinel: DLL_Node<T>;
	DLL_Next: DLL_Node<T>;
	DLL_Prev: DLL_Node<T>;
}
local function DLL_Create<T>(): DLL_Node<T>
	local DLL = {} :: DLL_Node<T>
	DLL.DLL_Sentinel = DLL
	DLL.DLL_Next = DLL
	DLL.DLL_Prev = DLL
	return DLL
end
local function DLL_ClearSentinelReferences<T>(DLL: DLL_Node<T>)
	local Current = DLL.DLL_Next
	while Current ~= DLL do
		Current.DLL_Sentinel = nil :: any
		Current = Current.DLL_Next
	end
end
local function DLL_ClearLinks<T>(DLL: DLL_Node<T>)
	DLL.DLL_Next = DLL
	DLL.DLL_Prev = DLL
end
local function DLL_Append<T>(DLL: DLL_Node<T>, Node: DLL_Node<T>)
	Node.DLL_Sentinel = DLL
	Node.DLL_Next = DLL
	Node.DLL_Prev = DLL.DLL_Prev

	DLL.DLL_Prev.DLL_Next = Node
	DLL.DLL_Prev = Node
end
local function DLL_AppendFirst<T>(DLL: DLL_Node<T>, Node: DLL_Node<T>)
	Node.DLL_Sentinel = DLL.DLL_Sentinel
	Node.DLL_Next = DLL.DLL_Next
	Node.DLL_Prev = DLL
	
	DLL.DLL_Next.DLL_Prev = Node
	DLL.DLL_Next = Node
end
local function DLL_IsInside<T>(DLL: DLL_Node<T>, Node: DLL_Node<T>): boolean
	return Node.DLL_Sentinel == DLL
end
local function DLL_IsSentinel<T>(Node: DLL_Node<T>): boolean
	return Node.DLL_Sentinel == Node
end
local function DLL_Remove<T>(Node: DLL_Node<T>)
	if Node.DLL_Sentinel then
		Node.DLL_Sentinel = nil :: any
		Node.DLL_Next.DLL_Prev = Node.DLL_Prev
		Node.DLL_Prev.DLL_Next = Node.DLL_Next
	end
end

-- Weak Arrays
local function WeakArrayAppendOnce<T>(Array: {T}?, Value: T): {T}?
	if Value ~= nil then
		if not Array then
			Array = {Value}
		elseif not table.find(Array, Value) then
			Array[#Array+1] = Value
		end
	end
	return Array
end
local function WeakArrayDelete<T>(Array: {T}?, Value: T): {T}?
	if Array then
		local Index = table.find(Array, Value)
		if Index then
			table.remove(Array, Index)
			if not Array[1] then
				Array = nil
			end
		end
	end
	return Array
end

--
-- Shared API
--

function Module.IdFromStrings(Strings: {string})
	return table.concat(Strings, ";") 
end
function Module.StringsFromId(Id: string): {string}
	return string.split(Id, ";")
end

Module.RequestId = {
	subscribe = "s";
	unsubscribe = "u";
}
export type AssetRequest = {string} -- {RequestId, AssetId}

export type AssetResponse = {
	Id: string;
	Asset: Instance;
	DescCount: number;
}

--
-- Server API
--

-- To send assets to a client, do these steps:
-- 1. Parent the instance to their PlayerGui, 
-- 2. Immediately fire a remote which references the instance
-- 3. Immediately reparent the instance elsewhere
--
-- This API provides some helpers for this work. They are marked by the step
-- they are relevant to.
--
-- Some example usage code of this API:
--[[

local AssetDatabase = {
	Frog = game.ServerStorage.Frog;
}

local Replicator_ByPlayer = {}
Players.PlayerAdded:Connect(function(Player)
	Replicator_ByPlayer[Player] = Instreamer.CreateReplicator(Player)
end)

RunService.Heartbeat:Connect(function()
	local AssetSender = Instreamer.AS_Create()
	for _, Player in Players:GetPlayers() do
		local Replicator = Replicator_ByPlayer[Player]
		
		local SentAssets = {}
		for _, AssetId in AssetIdsToSend_ByPlayer[Player] do
			local AssetInstance = AssetDatabase[AssetId]
			
			Instreamer.AS_Send(AssetSender, Replicator, AssetInstance)
			SentAssets[#SentAssets+1] = Instreamer.MakeResponse(AssetId, AssetInstance)
		end
		table.clear(AssetIdsToSend_ByPlayer[Player])
		
		if SentAssets[1] then
			RemoteEvent:FireClient(Player, SentAssets)
		end
	end
	Instreamer.AS_Finish(AssetSender)
end)

--]]

-- (Step 2) A RemoteEvent should be fired to the client while the instance is 
-- parented under their PlayerGui. This function .MakeAssetResponse() can be 
-- used to get the data that should be sent to the client through that 
-- RemoteEvent. You can send AssetResponses in bulk with a single firing of the 
-- RemoteEvent, provided all of the asset instances are still parented under 
-- PlayerGui at the time it is fired.
function Module.MakeAssetResponse(
	Id: string,
	Asset: Instance,
	DescendantCount: number?
): AssetResponse
	return {
		Id = Id;
		Asset = Asset;
		DescCount = DescendantCount or #Asset:GetDescendants();
	}
end

-- (Step 1) Replicator is just a quick way of creating a dedicated replication 
-- container for a player, that is guaranteed not to be reset when a player 
-- respawns their character (I don't know whether that is an actual issue or not
-- for this kind of replication, but I'd rather be safe than sorry).
export type Replicator = ScreenGui
function Module.CreateReplicator(Player: Player): Replicator
	local ScreenGui = Instance.new("ScreenGui")
	ScreenGui.Enabled = false
	ScreenGui.ResetOnSpawn = false
	ScreenGui.Name = "StreamerReplicator"
	ScreenGui.Parent = Player.PlayerGui
	return ScreenGui
end

-- (Step 1 & 3) AssetSender allows for replicating assets to different players 
-- at once while minimizing the number of unnecessary reparents. It's lifetime 
-- is only for a single frame (or usage site). For example if you need to 
-- replicate assets to many different players: create one AssetSender, use 
-- .AS_Send() to send the assets to all players, then call .AS_Finish() at the 
-- end, then forget the AssetSender.
export type AssetSender = {
	Parent_ByAsset: {[Instance]: {Instance?}};
}
function Module.AS_Create(): AssetSender
	return {
		Parent_ByAsset = {};
	}
end
function Module.AS_Send(
	AS: AssetSender,
	
	-- For this argument pass the Replicator if you created one. Otherwise you 
	-- should pass PlayerGui or a descendant of it.
	Parent: Instance,
	
	Asset: Instance
)
	if PRF_ON then debug.profilebegin("Instreamer_AS_Send") end
	
	if not AS.Parent_ByAsset[Asset] then
		-- An asset's original parent may be nil, so we need to wrap each parent 
		-- in an array to guarantee that the asset is stored in the hash table no 
		-- matter what it's original parent was.
		AS.Parent_ByAsset[Asset] = {Asset.Parent}
	end
	Asset.Parent = Parent
	
	if PRF_ON then debug.profileend() end
end
function Module.AS_Finish(AS: AssetSender)
	if PRF_ON then debug.profilebegin("Instreamer_AS_Finish") end
	
	for Asset, Wrapper in AS.Parent_ByAsset do
		Asset.Parent = Wrapper[1]
	end
	
	if PRF_ON then debug.profileend() end
end

--
-- Client API
--

export type AssetHandle = {
	Id: string;
	
	-- The asset instance, fully replicated and ready for use.
	Asset: Instance?;
	
	-- Callbacks is a persistent table of functions that will be called when the 
	-- asset loads. (This includes when an asset is replaced by the same asset 
	-- that has been replicated again.) It is safe to call .AH_AddCallback and 
	-- .AH_RemoveCallback in callbacks.
	Callbacks: {AssetLoadedCallback}?;
	
	-- Threads is similar to callbacks, except that the threads table will be 
	-- cleared when threads are resumed. It is safe to call .AH_AddThread and 
	-- .AH_RemoveThread in these resumed threads.
	Threads: {thread}?;
	
	--
	-- Internal fields
	--
	
	-- These are markers to indicate who is currently using the asset.
	Immediate: boolean?;
	-- @Cleanup Using an array for this may be slow but it'll do for now.
	Retained: {any}?;
	
	-- The timestamp when the asset should be unsubscribed and destroyed, used
	-- only while the asset is unused and in the StreamerClient.DLL_Cache.
	ExpireAt: number;
	
	-- The recieved asset that has not been fully replicated yet (or at least has
	-- not yet been checked whether it has fully replicated or not). If the
	-- server replicates the same asset multiple times, the latest asset will also
	-- be present here until it has fully loaded and replaced .Asset.
	Incomplete: DLL_Node<AssetIncomplete>?;
}
export type AssetIncomplete = {
	Handle: AssetHandle;
	Asset: Instance;
	Count: number;
	Connection: RBXScriptConnection;
}
export type AssetLoadedCallback =
	(Asset: Instance, Handle: AssetHandle, SC: StreamerClient)->()

function Module.AH_AddCallback(Handle: AssetHandle, Callback: AssetLoadedCallback)
	Handle.Callbacks = WeakArrayAppendOnce(Handle.Callbacks, Callback)
end
function Module.AH_RemoveCallback(Handle: AssetHandle, Callback: AssetLoadedCallback)
	Handle.Callbacks = WeakArrayDelete(Handle.Callbacks, Callback)
end
function Module.AH_AddThread(Handle: AssetHandle, Thread: thread)
	Handle.Threads = WeakArrayAppendOnce(Handle.Threads, Thread)
end
function Module.AH_RemoveThread(Handle: AssetHandle, Thread: thread)
	Handle.Threads = WeakArrayDelete(Handle.Threads, Thread)
end
function Module.AH_YieldUntilReady(Handle: AssetHandle)
	if not Handle.Asset then
		Module.AH_AddThread(Handle, coroutine.running())
		coroutine.yield()
	end
end

-- Internal functions
local function AH_DestroyAsset(Handle: AssetHandle)
	local Asset = Handle.Asset
	if Asset then
		Handle.Asset = nil
		Asset:Destroy()
	end
end
local function AH_DestroyIncomplete(Handle: AssetHandle)
	local Incomplete = Handle.Incomplete
	if Incomplete then
		Handle.Incomplete = nil
		Incomplete.Connection:Disconnect()
		Incomplete.Asset:Destroy()
		DLL_Remove(Incomplete)
	end
end

export type StreamerClient = {
	-- Outgoing asset streaming requests that need to be processed by game code 
	-- every frame.
	PendingRequests: {AssetRequest};
	
	-- Optional log function for displaying debug logs. The presence of the 
	-- function is used to indicate whether you want logs to happen or not.
	LogFunction: ((string)->())?;
	
	--
	-- Internal fields
	--
	
	Handle_ById: {[string]: DLL_Node<AssetHandle>};
	
	-- How long unused assets will sit in the cache until they will be 
	-- unsubscribed from and destroyed. DO NOT CHANGE THIS AT RUNTIME, as the 
	-- cache avoids unnecessary work by assuming ordering of list elements.
	CacheExpiry: number;
	
	-- _Used and _Unused are relevant only for the immediate mode API.
	-- _Cache is used by both immediate and retained mode API, when neither of
	-- them are using the asset anymore.
	DLL_Used: DLL_Node<AssetHandle>;
	DLL_Unused: DLL_Node<AssetHandle>;
	DLL_Cache: DLL_Node<AssetHandle>;
	
	-- Tracks incomplete assets that are "dirty" (something has changed and they 
	-- need to be checked again to see if they have finished replicating).
	DLL_CheckAsset: DLL_Node<AssetIncomplete>;
}

function Module.SC_Create(CacheExpiry: number?): StreamerClient
	local SC = {} :: StreamerClient
	SC.Handle_ById = {}
	SC.DLL_Used = DLL_Create()
	SC.DLL_Unused = DLL_Create()
	SC.DLL_Cache = DLL_Create()
	SC.DLL_CheckAsset = DLL_Create()
	SC.PendingRequests = {}
	SC.CacheExpiry = CacheExpiry or 10
	return SC
end

-- Call this in the remote event listeners which recieve assets and start 
-- tracking them.
function Module.SC_ReceiveAssets(SC: StreamerClient, Assets: {AssetResponse})
	if PRF_ON then debug.profilebegin("Instreamer_SC_CheckAssets") end
	
	for _, Response in Assets do
		local Handle = SC.Handle_ById[Response.Id]
		local Asset = Response.Asset
		if not Handle then
			Asset:Destroy()
			
		elseif Asset then
			
			-- @Cleanup Parenting the asset to nil may prevent the instance from 
			-- fully replicating if it is recieved partially replicated. However, 
			-- according to my tests, this replication is always atomic. So I guess
			-- we don't need to worry about that. This means all the 
			-- AssetIncomplete stuff is unnecessary and we can delete that. But for
			-- the time being I will keep that stuff in order to confirm if assets
			-- will ever fail to replicate fully.
			
			Asset.Parent = nil
			
			AH_DestroyIncomplete(Handle)
			
			if SC.LogFunction then
				SC.LogFunction(("rec \"%s\""):format(Response.Id))
			end
			
			local Incomplete = {} :: DLL_Node<AssetIncomplete>
			Incomplete.Handle = Handle
			Incomplete.Asset = Asset
			Incomplete.Count = Response.DescCount
			Incomplete.Connection = Asset.DescendantAdded:Connect(function()
				if (Handle.Incomplete == Incomplete) and
					(not DLL_IsInside(SC.DLL_CheckAsset, Incomplete))
				then
					DLL_Remove(Incomplete)
					DLL_Append(SC.DLL_CheckAsset, Incomplete)
				end
			end)
			Handle.Incomplete = Incomplete
			DLL_Append(SC.DLL_CheckAsset, Incomplete)
		end
	end
	
	if PRF_ON then debug.profileend() end
end

-- Call this at the beginning of a frame to mark assets as completed when they 
-- finish replicating. (You should do this as soon as possible after 
-- SC_ReceiveAssets.)
function Module.SC_CheckAssets(SC: StreamerClient)
	if PRF_ON then debug.profilebegin("Instreamer_SC_CheckAssets") end
	
	local Current = SC.DLL_CheckAsset.DLL_Next
	while Current ~= SC.DLL_CheckAsset do
		local Incomplete = Current
		Current = Current.DLL_Next
		
		DLL_Remove(Incomplete)
		
		local Count = #Incomplete.Asset:GetDescendants()
		if Count < Incomplete.Count then
			
			-- @IncompleteAsset I believe that replication of instance through 
			-- PlayerGui is atomic. Moreover, this module has not been fully tested
			-- in non-atomic circumstances because they could not be produced.
			--
			-- So it is likely that incomplete is more of a permanent issue, caused
			-- by some descendants existing on the server that were not replicated
			-- to the client, or by descendants that were deleted by other parts of
			-- the game's client-side codebase.
			--
			-- If you cannot avoid that server/client difference, then on the 
			-- server you should pass a custom DescendantCount into 
			-- .MakeAssetResponse(), so that the differences between client and 
			-- server are accounted for and the server tells the client to expect
			-- the correct number of descendants.
			
			warn(("[Instreamer] Asset '%s' was recieved with only %d / %d descendants. Is there a difference in its descendants between server and client? See @IncompleteAsset for more info.")
				:format(Incomplete.Handle.Id, Count, Incomplete.Count))
			
			-- More generalized log to make it be aggregated and show up in the 
			-- experience's Error Report.
			warn(("[Instreamer] Asset was received while missing descendants. See @IncompleteAsset for more info."))
			
		else
			local Handle = Incomplete.Handle
			
			Handle.Incomplete = nil
			Incomplete.Connection:Disconnect()
			
			AH_DestroyAsset(Handle)
			Handle.Asset = Incomplete.Asset
			
			if SC.LogFunction then
				SC.LogFunction(("com \"%s\""):format(Handle.Id))
			end
			
			local Callbacks = Handle.Callbacks
			if Callbacks then
				for _, Callback in table.clone(Callbacks) do
					task.spawn(Callback, Incomplete.Asset, Handle, SC)
				end
			end
			
			local Threads = Handle.Threads
			if Threads then
				Handle.Threads = nil
				for _, Thread in Threads do
					task.spawn(Thread, Incomplete.Asset, Handle, SC)
				end
			end
		end
	end
	
	if PRF_ON then debug.profileend() end
end

-- Call this at the end of every frame to clear the cache and clean up unused 
-- immediate-mode assets.
function Module.SC_CleanupAssets(SC: StreamerClient, Now: number)
	if PRF_ON then debug.profilebegin("Instreamer_SC_CleanupAssets") end
	
	-- Clean up expired cached assets.
	local Current = SC.DLL_Cache.DLL_Next
	while Current ~= SC.DLL_Cache do
		local Handle = Current
		Current = Current.DLL_Next
		
		if Now < Handle.ExpireAt then
			break
		else
			DLL_Remove(Handle)
			SC.Handle_ById[Handle.Id] = nil
			SC.PendingRequests[#SC.PendingRequests+1] =
				{Module.RequestId.unsubscribe; Handle.Id}
			AH_DestroyAsset(Handle)
			AH_DestroyIncomplete(Handle)
			
			if SC.LogFunction then
				SC.LogFunction(("uns \"%s\""):format(Handle.Id))
			end
		end
	end
	
	-- Clean up all unused immediate-mode assets.
	local Current = SC.DLL_Unused.DLL_Next
	while Current ~= SC.DLL_Unused do
		local Handle = Current
		Current = Current.DLL_Next
		
		DLL_Remove(Handle)
		Handle.Immediate = nil
		
		if not Handle.Retained then
			Handle.ExpireAt = Now + SC.CacheExpiry
			DLL_Append(SC.DLL_Cache, Handle)
		end
	end
	
	-- Swap used and unused for the next frame.
	local DLL_Unused = SC.DLL_Unused
	SC.DLL_Unused = SC.DLL_Used
	SC.DLL_Used = DLL_Unused
	
	if PRF_ON then debug.profileend() end
end

-- Note on immediate & retained mode APIs: Both modes can be used at the same 
-- time for the same StreamerClient. The modes will not affect each other: an 
-- asset will be considered subscribed to if it is still being used by either 
-- mode. When an asset is no longer used by any mode, it will be put into the 
-- cache, then eventually deleted.

-- Immediate-mode API. Call this when you want to implicitly subscribe to
-- an asset at the same time as trying to retrieve it.
function Module.SC_Use(SC: StreamerClient, Id: string): Instance?
	if PRF_ON then debug.profilebegin("Instreamer_SC_Use") end
	
	if not SC.Handle_ById[Id] then
		local Handle = {} :: DLL_Node<AssetHandle>
		SC.Handle_ById[Id] = Handle
		Handle.Id = Id
		Handle.ExpireAt = -math.huge
		SC.PendingRequests[#SC.PendingRequests+1] =
			{Module.RequestId.subscribe; Handle.Id}
		
		if SC.LogFunction then
			SC.LogFunction(("sub \"%s\""):format(Handle.Id))
		end
	end
	
	local Handle = SC.Handle_ById[Id]
	Handle.Immediate = true
	if not DLL_IsInside(SC.DLL_Used, Handle) then
		DLL_Remove(Handle)
		DLL_Append(SC.DLL_Used, Handle)
	end
				
	if PRF_ON then debug.profileend() end		
				
	return Handle.Asset
end

-- Retained-mode API. Call the subscribe and unsubscribe functions as needed. As
-- well as the asset ID, you must provide a key which is used to identify the 
-- particular code or game system that wants to use the asset, so different game
-- systems can all use the same asset without knowing about each other.
function Module.SC_Subscribe(SC: StreamerClient, Id: string, Key: any): AssetHandle
	if PRF_ON then debug.profilebegin("Instreamer_SC_Subscribe") end
	
	if not SC.Handle_ById[Id] then
		local Handle = {} :: DLL_Node<AssetHandle>
		SC.Handle_ById[Id] = Handle
		Handle.Id = Id
		Handle.ExpireAt = -math.huge
		SC.PendingRequests[#SC.PendingRequests+1] =
			{Module.RequestId.subscribe; Handle.Id}
		
		if SC.LogFunction then
			SC.LogFunction(("sub \"%s\""):format(Handle.Id))
		end
	end
	
	local Handle = SC.Handle_ById[Id]
	do
		local Retained = Handle.Retained
		if not Retained then
			Handle.Retained = {Key}
		elseif not table.find(Retained, Key) then
			Retained[#Retained+1] = Key
		end
	end
	if DLL_IsInside(SC.DLL_Cache, Handle) then
		DLL_Remove(Handle)
	end
	
	if PRF_ON then debug.profileend() end	
	
	return Handle
end
function Module.SC_Unsubscribe(SC: StreamerClient, Id: string, Key: any, Now: number)
	if PRF_ON then debug.profilebegin("Instreamer_SC_Unsubscribe") end
	
	local Handle = SC.Handle_ById[Id]
	if Handle then
		
		local Retained = Handle.Retained
		if Retained then
			local Index = table.find(Retained, Key)
			if Index then
				table.remove(Retained, Key)
				if not Retained[1] then
					Handle.Retained = nil
					
					if not Handle.Immediate then
						Handle.ExpireAt = Now + SC.CacheExpiry
						DLL_Remove(Handle) -- Shouldn't be necessary, but let's be safe.
						DLL_Append(SC.DLL_Cache, Handle)
					end
				end
			end
		end
	end
	
	if PRF_ON then debug.profileend() end	
end

return Module