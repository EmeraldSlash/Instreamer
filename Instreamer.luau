--!strict

-- Instreamer: Per-player instance streaming.
--
-- https://github.com/EmeraldSlash/Instreamer
--
-- Created by Rio Manson-Hay (@EmeraldSlash)
--
-- Version: 3 (2025-08-01)
--
-- Change Log:
--
-- Version 1: Initial version.
--
-- Version 2: Added High-Level API, and categorized the Low-Level API and Helper
-- API.
--
-- Version 3: Improved High-Level API and fixed some small bugs.

--------------------------------------------------------------------------------

--
-- HELPER API:
-- These are generic helpers for everyone using the module.
--
-- .IdFromStrings(): string
-- .StringsFromId(): {string}

--------------------------------------------------------------------------------

--
-- HIGH-LEVEL API (HAPI):
-- This is an easy API for developers who don't need much control.
--
-- Server:
--
-- type GetAssetCallback
-- Module.ServerInit(GetAssetCallback)
--
-- Client:
--
-- Module.ClientInit(): StreamerClient
-- Module.ClientUse(): Instance?        (immediate-mode)
-- Module.ClientSubscribe(): ClientSub  (retained-mode)
--
-- type ClientSub
-- type ClientSubLoadedCallback
-- ClientSub:Unsubscribe(): ClientSub
-- ClientSub:GetNow(): Instance?
-- ClientSub:GetAsync(): Instance?
-- ClientSub:OnLoaded(ClientSubLoadedCallback): ClientSubConnection
--
-- type ClientSubConnection
-- ClientSubConnection:Disconnect/Destroy()

--------------------------------------------------------------------------------

-- LOW-LEVEL API (LAPI):
-- This is an API for developers who want more control.
--
-- Shared:
--
-- .RequestId: enum
-- type AssetRequest
-- type AssetResponse
--
-- Server:
--
-- .MakeAssetResponse(): AssetResponse
--
-- type Replicator
-- .CreateReplicator(): Replicator
--
-- type AssetSender
-- .AS_Create(): AssetSender
-- .AS_Send()
-- .AS_Finish()
--
-- Client:
--
-- type AssetHandle
-- type AssetIncomplete
-- type AssetLoadedCallback
-- .AH_AddCallback()
-- .AH_RemoveCallback()
-- .AH_AddThread()
-- .AH_RemoveThread()
-- .AH_YieldUntilReady()
--
-- type StreamerClient
-- .SC_Create(): StreamerClient
-- .SC_ReceiveAssets()
-- .SC_CheckAssets()
-- .SC_CleanupAssets()
-- .SC_Use(): Instance?             (immediate-mode)
-- .SC_Subscribe(): AssetHandle     (retained-mode)
-- .SC_Unsubscribe()                (retained-mode)

--------------------------------------------------------------------------------

local Module = {}

-- Enable/disable microprofiler labels.
local PRF_ON = false

--
-- Internal utilities
--

-- Doubly Linked List
--
-- Here is the idiomatic & most efficient way to walk the linked list:
--[[
local DLL_Current = DLL_Sentinel.DLL_Next
while DLL_Current ~= DLL_Sentinel do
	local Element = DLL_Current
	DLL_Current = DLL_Current.DLL_Next

	-- It is safe to remove elements after the Current pointer has been moved to
	-- the next node.
	DLL_Remove(Element)

	-- Do other stuff with Element here.
end
--]]
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

--------------------------------------------------------------------------------

--
-- HELPER API
--

function Module.IdFromStrings(Strings: {string})
	return table.concat(Strings, ";")
end
function Module.StringsFromId(Id: string): {string}
	return string.split(Id, ";")
end

--------------------------------------------------------------------------------

--
-- LOW-LEVEL API (LAPI)
--

--
-- LAPI Shared
--

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
-- LAPI Server
--

-- To send assets to a client, do these steps:
-- 1. Parent the instance to their PlayerGui,
-- 2. Immediately fire a remote which references the instance
-- 3. Immediately reparent the instance elsewhere
--
-- This API provides some helpers for this work. They are marked by the step
-- they are relevant to.

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
-- LAPI Client
--

export type AssetHandle = {
	--
	-- Exposed fields
	--

	Id: string;

	-- The asset instance, fully replicated and ready for use.
	Asset: Instance?;

	-- Callbacks is a table of functions that will be called when the asset
	-- loads. An asset may load more than once, as the server may send the asset
	-- again for some reason, so the callback should not assume it will only be
	-- called once. It is safe to call .AH_AddCallback and .AH_RemoveCallback in
	-- callbacks.
	Callbacks: {AssetLoadedCallback}?;

	-- Threads is similar to callbacks, except that the threads table will be
	-- cleared when threads are resumed. It is safe to call .AH_AddThread and
	-- .AH_RemoveThread in these resumed threads, though the latter should be
	-- unnecessary.
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
	--
	-- Exposed fields
	--

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
	if PRF_ON then debug.profilebegin("Instreamer_SC_ReceiveAssets") end

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

	assert(Key ~= nil, "[Instreamer] Cannot subscribe to an asset without a key.")

	if SC.Handle_ById[Id] then
		warn(debug.traceback(("[Instreamer] Asset \"%s\" already has a subscription with key: %s. To avoid aliasing you should use a different key for every subscription."):format(Id, tostring(Key))))
	else
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
	Handle.Retained = WeakArrayAppendOnce(Handle.Retained, Key)
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

		-- WeakArrayDelete is manually written here because we need to guard
		-- the destructor code and it's not worth the extra complexity to make
		-- the function support that.
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

--------------------------------------------------------------------------------

--
-- HIGH-LEVEL API (HAPI)
--

--
-- HAPI Server
--

local RunService = game:GetService("RunService")

export type GetAssetCallback = (Player: Player, AssetId: string)->(Instance?)

do
	type PlayerState = {
		Replicator: Replicator;
		PendingAssetRequests: {AssetRequest};
		Subscribed_ByAssetId: {[string]: boolean};
	}

	local State = (function() return { -- Function to seal table type.

		Initialized = false;
		PS_ByPlayer = {} :: {[Player]: PlayerState};

	} end)()

	-- Module.ServerInit()
	--
	-- You must call this function server-side to get things up and running.
	--
	-- The GetAssetCallback function must be provided, as it is responsible for
	-- looking up an instance that is able to be replicated to a particular
	-- player. For example, the callback could look up the asset in a table, and
	-- check whether the player is allowed to receive the asset. The callback
	-- should return nil if an asset does not exist or the player is not allowed
	-- to receive it.
	--
	function Module.ServerInit(GetAssetCallback: GetAssetCallback)
		if not State.Initialized then
			State.Initialized = true

			local Players = game:GetService("Players")
			Players.PlayerAdded:Connect(function(Player: Player)
				local PS = {} :: PlayerState
				PS.Replicator = Module.CreateReplicator(Player)
				PS.PendingAssetRequests = {}
				PS.Subscribed_ByAssetId = {}
				State.PS_ByPlayer[Player] = PS
			end)
			Players.PlayerRemoving:Connect(function(Player: Player)
				local PS = State.PS_ByPlayer[Player]
				if PS then
					State.PS_ByPlayer[Player] = nil
					PS.Replicator:Destroy()
				end
			end)

			local RemoteEvent = Instance.new("RemoteEvent")
			RemoteEvent.Name = "InstreamerRemote"
			RemoteEvent.Parent = script
			RemoteEvent.OnServerEvent:Connect(function(
				Player: Player,
				Requests: {AssetRequest}
			)
				local PS = State.PS_ByPlayer[Player]
				if PS then
					for _, Request in Requests do
						PS.PendingAssetRequests[#PS.PendingAssetRequests+1] = Request
					end
				end
			end)

			RunService.Heartbeat:Connect(function()
				if PRF_ON then debug.profilebegin("Instreamer_ServerHbt") end

				local AssetSender = Module.AS_Create()

				for Player, PS in State.PS_ByPlayer do

					-- Process all requests in a first pass to avoid duplication of
					-- asset getter & replication work.
					local Subscribed_ByAssetId = {}
					for _, Request in PS.PendingAssetRequests do
						local AssetId = Request[2]
						if type(AssetId) == "string" then
							local RequestId = Request[1]
							if RequestId == Module.RequestId.unsubscribe then
								Subscribed_ByAssetId[AssetId] = false
							elseif RequestId == Module.RequestId.subscribe then
								Subscribed_ByAssetId[AssetId] = true
							end
						end
					end
					table.clear(PS.PendingAssetRequests)

					-- Second pass to apply the subscription state changes and
					-- replicate assets.
					local SentAssets = {}
					for AssetId, NewSubscribed in Subscribed_ByAssetId do
						if not NewSubscribed then
							PS.Subscribed_ByAssetId[AssetId] = nil

						elseif not PS.Subscribed_ByAssetId[AssetId] then
							local AssetInstance = GetAssetCallback(Player, AssetId)
							if not AssetInstance then
								PS.Subscribed_ByAssetId[AssetId] = nil
							else
								PS.Subscribed_ByAssetId[AssetId] = true

								Module.AS_Send(AssetSender, PS.Replicator, AssetInstance)
								SentAssets[#SentAssets+1] =
									Module.MakeAssetResponse(AssetId, AssetInstance)
							end
						end
					end
					if SentAssets[1] then
						RemoteEvent:FireClient(Player, SentAssets)
					end
				end

				Module.AS_Finish(AssetSender)

				if PRF_ON then debug.profileend() end
			end)
		end
	end
end

--
-- HAPI Client
--

do
	local State = (function() return { -- Function to seal table type.

		Initializing = false;
		SC = (nil :: any) :: StreamerClient; -- Initialized later.
		PendingResponses = {} :: {AssetResponse};

	} end)()

	local IsClient = RunService:IsClient()
	local function RequireClient()
		if not IsClient then
			error("Instreamer.Client* functions can only be used on the client!")
		end
	end

	local function ClientInitInternal()
		if not State.Initializing then
			State.Initializing = true

			-- This must be set immediately so it can be accessed by usage code.
			State.SC = Module.SC_Create()

			-- All the setup work which may yield is done in here, transparently to
			-- the usage code. Usage code will never experience a yield and
			-- shouldn't need to care about timing stuff.
			task.spawn(function()

				local RemoteEvent = script:WaitForChild("InstreamerRemote") :: Instance
				assert(RemoteEvent:IsA("RemoteEvent"), "InstreamerRemote was not a RemoteEvent!")
				RemoteEvent.OnClientEvent:Connect(function(Responses)
					table.move(
						Responses, 1, #Responses,
						#State.PendingResponses+1, State.PendingResponses)
				end)

				RunService.Heartbeat:Connect(function()
					if PRF_ON then debug.profilebegin("Instreamer_ClientHbt") end

					Module.SC_ReceiveAssets(State.SC, State.PendingResponses)
					table.clear(State.PendingResponses)

					Module.SC_CheckAssets(State.SC)
					Module.SC_CleanupAssets(State.SC, os.clock())

					local Requests = State.SC.PendingRequests
					if Requests[1] then
						RemoteEvent:FireServer(Requests)
						table.clear(Requests)
					end

					if PRF_ON then debug.profileend() end
				end)
			end)
		end
	end

	export type ClientSub = {
		-- Internal fields
		Handle: AssetHandle;
		Key: any;
		Threads: {thread};
		GetAsyncCallback: AssetLoadedCallback?;
		LoadedCallback: AssetLoadedCallback?;
		LoadedConnections: {ClientSubConnection}?;

		-- Exposed methods
		Unsubscribe: (ClientSub)->();
		GetNow: (ClientSub)->();
		GetAsync: (ClientSub)->();
		OnLoaded: (ClientSub, ClientSubLoadedCallback)->(ClientSubConnection);
	}
	export type ClientSubConnection = {
		-- Internal fields
		CS: ClientSub;
		Callback: ClientSubLoadedCallback;

		-- Exposed fields
		Connected: boolean; -- You can read this to check if still connected.

		-- Exposed methods
		Destroy: (ClientSubConnection)->();
		Disconnect: (ClientSubConnection)->();
	}
	export type ClientSubLoadedCallback = (Asset: Instance, CS: ClientSub, CSC: ClientSubConnection)->()

	-- ClientSubConnection:Disconnect()
	-- ClientSubConnection:Destroy()
	--
	-- Cleans up the connection. It is safe to do this from within callbacks.
	--
	local function CSC_Destroy(CSC: ClientSubConnection)
		if CSC.Connected then
			CSC.Connected = false
			CSC.CS.LoadedConnections = WeakArrayDelete(CSC.CS.LoadedConnections, CSC)
		end
	end

	-- ClientSub:Unsubscribe()
	--
	-- Unsubscribes from the asset. This will resume any waiting GetAsync() or
	-- other threads.
	--
	local function CS_Unsubscribe(CS: ClientSub): ClientSub
		Module.SC_Unsubscribe(State.SC, CS.Handle.Id, CS.Key, os.clock())

		if CS.GetAsyncCallback then
			Module.AH_RemoveCallback(CS.Handle, CS.GetAsyncCallback)
		end
		if CS.LoadedCallback then
			Module.AH_RemoveCallback(CS.Handle, CS.LoadedCallback)
		end

		if CS.LoadedConnections then
			for _, Conn in CS.LoadedConnections do
				Conn.Connected = false
			end
			CS.LoadedConnections = nil
		end

		local Threads = table.clone(CS.Threads)
		table.clear(CS.Threads)
		for _, Thread in Threads do
			task.spawn(Thread, nil, CS.Handle, State.SC)
		end

		return CS
	end

	-- ClientSub:GetNow()
	--
	-- Retrieves the asset immediately, if it's available.
	--
	local function CS_GetNow(CS: ClientSub): Instance?
		return CS.Handle.Asset
	end

	-- ClientSub:GetAsync()
	--
	-- Yields the calling thread until 1) asset is loaded or 2) the asset has
	-- been unsubscribed from. Will return the asset if is available.
	--
	local function CS_GetAsync(CS: ClientSub): Instance?
		if not CS.Handle.Asset then

			if not CS.GetAsyncCallback then
				CS.GetAsyncCallback = function(Asset)
					local Threads = CS.Threads
					table.clear(CS.Threads)
					for _, Thread in Threads do
						task.spawn(Thread, Asset, CS)
					end
				end
				Module.AH_AddCallback(CS.Handle, CS.GetAsyncCallback :: any)
			end

			CS.Threads[#CS.Threads+1] = coroutine.running()
			coroutine.yield()
		end
		return CS.Handle.Asset
	end

	-- ClientSub:OnLoaded()
	--
	-- Binds what is essentially a signal connection to the asset subscription,
	-- so that the callback is executed whenever a new version of the asset has
	-- loaded. Returns a Connection object that you can Disconnect/Destroy.
	--
	-- The callback may execute more than once per binding if the asset gets sent
	-- to the client twice, so if you only want it to be called once you should
	-- disconnect the connection immediately within the callback (the connection
	-- is provided as the third argument to the callback to make this more
	-- convenient).
	--
	local function CS_OnLoaded(CS: ClientSub, Callback: ClientSubLoadedCallback): ClientSubConnection
		if not CS.LoadedCallback then
			CS.LoadedCallback = function(Asset)
				if Asset and CS.LoadedConnections then
					for _, Conn in table.clone(CS.LoadedConnections) do
						Conn.Callback(Asset, CS, Conn)
					end
				end
			end
			Module.AH_AddCallback(CS.Handle, CS.LoadedCallback :: any)
		end

		local Conn: ClientSubConnection = {
			CS = CS;
			Callback = Callback;
			Connected = true;

			Destroy = CSC_Destroy;
			Disconnect = CSC_Destroy;
		}
		CS.LoadedConnections = WeakArrayAppendOnce(CS.LoadedConnections, Conn)
		return Conn
	end

	-- Module.ClientInit()
	--
	-- You can call this after requiring the module to get things up and running,
	-- but it will be called automatically when other functions are called so
	-- that is optional. You can call this function as many times as you like.
	--
	-- It will also return the StreamerClient when called, so you can use it to
	-- get access to the LAPI if you wish.
	--
	-- You do not need to call this function if you are only using the HAPI with
	-- StreamerClients created by your own code.
	--
	function Module.ClientInit(): StreamerClient
		RequireClient()
		ClientInitInternal()

		return State.SC
	end

	-- Module.ClientUse()
	--
	-- Immediate-mode API: Call this every frame that you want an asset to be
	-- used, or at least available for use. If the asset is available at the time
	-- of the call it will be returned.
	--
	-- You can optionally provide a StreamerClient that you created manually if
	-- you want to use this HAPI function on it.
	--
	function Module.ClientUse(Id: string, SC: StreamerClient?): Instance?
		RequireClient()
		if not SC then ClientInitInternal() end

		return Module.SC_Use(SC or State.SC, Id)
	end

	-- Module.ClientSubscribe()
	--
	-- Retained-mode API: Call this when you want to subscribe to some asset.
	-- Returns a ClientSub table which has facilities to retrieve the asset
	-- instance or unsubscribe from the asset.
	--
	-- You can optionally provide a key to identify this subscription in the
	-- StreamerClient, otherwise the ClientSub table will be used.
	--
	-- You can optionally provide a StreamerClient that you created manually if
	-- you want to use this HAPI function on it.
	--
	function Module.ClientSubscribe(Id: string, Key: any?, SC: StreamerClient?): ClientSub
		RequireClient()
		if not SC then ClientInitInternal() end

		local CS: ClientSub = {
			Handle = nil :: any;
			Key = nil :: any;
			Threads = {};

			Unsubscribe = CS_Unsubscribe;
			GetNow = CS_GetNow;
			GetAsync = CS_GetAsync;
			OnLoaded = CS_OnLoaded;
		}

		local RealKey = if Key ~= nil then Key else CS
		CS.Key = RealKey
		CS.Handle = Module.SC_Subscribe(SC or State.SC, Id, CS.Key)
		
		return CS
	end
end

return Module