#include <sourcemod>
#include <socket>
#include <colors>

#define PLUGIN_VERSION "1.1"
#define SOCKET_TIMEOUT 10.0
#define MAX_STR_LEN 255

public Plugin:myinfo = {
	name = "Redirect",
	author = "Unreal1",
	description = "",
	version = PLUGIN_VERSION,
	url = ""
};

new Handle:g_hDatabase = INVALID_HANDLE;

new Handle:g_hCVPrefix = INVALID_HANDLE;
new Handle:g_hCVRefreshInterval = INVALID_HANDLE;
new Handle:g_hCVAdvertInterval = INVALID_HANDLE;

new Handle:g_hAdTimer = INVALID_HANDLE;
new iAdTimerNextSID = 0;

new Handle:g_hServers = INVALID_HANDLE;
new Handle:g_hServerSockets = INVALID_HANDLE;

public OnPluginStart() {
	CreateConVar("sm_redirect_version", PLUGIN_VERSION, "Redirect version", FCVAR_DONTRECORD|FCVAR_PLUGIN|FCVAR_SPONLY|FCVAR_REPLICATED|FCVAR_NOTIFY);
	g_hCVPrefix = CreateConVar("sm_redirect_dbprefix", "sb", "Table prefix");
	g_hCVRefreshInterval = CreateConVar("sm_redirect_refreshinterval", "60.0", "", _, true, 30.0);
	g_hCVAdvertInterval = CreateConVar("sm_redirect_advertinterval", "120.0", "", _, true, 0.0);
	
	HookConVarChange(g_hCVAdvertInterval, OnCVAdvertIntervalChange);

	RegConsoleCmd("sm_servers", OnCmdRedirect);
	RegConsoleCmd("sm_hop", OnCmdRedirect);
	RegConsoleCmd("sm_serverhop", OnCmdRedirect);
	
	g_hServers = CreateArray();
	g_hServerSockets = CreateArray();
	
	InitDatabase();
}

public OnCVAdvertIntervalChange(Handle:cvar, const String:oldVal[], const String:newVal[]) {
	if (g_hAdTimer != INVALID_HANDLE) {
		KillTimer(g_hAdTimer);
		g_hAdTimer = INVALID_HANDLE;
	}
	if (GetConVarFloat(g_hCVAdvertInterval) != 0.0)
		g_hAdTimer = CreateTimer(GetConVarFloat(g_hCVAdvertInterval), OnTimerAdvert, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
	else
		g_hAdTimer = INVALID_HANDLE;
}

public Action:OnCmdRedirect(client, args) {
	if (GetArraySize(g_hServers) == 0) {
		ReplyToCommand(client, "There are no available servers");
		return Plugin_Handled;
	}
	
	new iPossibleServersCount = 0;
	new Handle:hMenu = CreateMenu(OnCmdRedirectMenu);
	SetMenuExitButton(hMenu, true);
	SetMenuTitle(hMenu, "Which server would you like to join?");
	SetMenuPagination(hMenu, 5);
	for (new i = 0; i < GetArraySize(g_hServers); i++) {
		new Handle:hServerTrie = GetArrayCell(g_hServers, i);
		new String:sIP[255], iPort, String:sName[MAX_STR_LEN], String:sMap[MAX_STR_LEN],
		iPlayers, iMaxPlayers;
		
		GetTrieString(hServerTrie, "ip", sIP, sizeof(sIP));
		GetTrieValue(hServerTrie, "port", iPort);
		GetTrieString(hServerTrie, "name", sName, sizeof(sName));
		GetTrieString(hServerTrie, "map", sMap, sizeof(sMap));
		GetTrieValue(hServerTrie, "players", iPlayers);
		GetTrieValue(hServerTrie, "maxplayers", iMaxPlayers);
		
		if (iPlayers == -1 || iMaxPlayers == -1)
			continue;
		
		new String:sItemInfo[255], String:sDisplayInfo[255];
		strcopy(sName, sizeof(sName), sName[19]);
		Format(sItemInfo, sizeof(sItemInfo), "%d|%d ", hServerTrie, i);
		Format(sDisplayInfo, sizeof(sDisplayInfo), "%s (%s) %d/%d", sName, sMap, iPlayers, iMaxPlayers);
		AddMenuItem(hMenu, sItemInfo, sDisplayInfo);
		
		iPossibleServersCount++;
	}
	if (iPossibleServersCount > 0)
		DisplayMenu(hMenu, client, MENU_TIME_FOREVER);
	else {
		ReplyToCommand(client, "There are no available servers");
		CloseHandle(hMenu);
		return Plugin_Handled;
	}
	
	return Plugin_Handled;
}

public OnCmdRedirectMenu(Handle:menu, MenuAction:action, client, item) {
	if (action == MenuAction_Select) {
		new String:sServerTrie[64], String:sI[64], String:sItem[255];
		GetMenuItem(menu, item, sItem, sizeof(sItem));
		new iIndex = SplitString(sItem, "|", sServerTrie, sizeof(sServerTrie));
		strcopy(sI, sizeof(sI), sItem[iIndex]);
		new Handle:hServerTrie = StringToInt(sServerTrie);
		new i = StringToInt(sI);
		new Handle:hTrie = GetArrayCell(g_hServers, i);
		if (hTrie == hServerTrie) {
			new Handle:hKV = CreateKeyValues("data");
			KvSetString(hKV, "time", "60");
			new String:sIP[255], iPort, String:sAddress[255];
			GetTrieString(hTrie, "ip", sIP, sizeof(sIP));
			GetTrieValue(hTrie, "port", iPort);
			Format(sAddress, sizeof(sAddress), "%s:%d", sIP, iPort);
			KvSetString(hKV, "title", sAddress);
			CreateDialog(client, hKV, DialogType_AskConnect);
			CloseHandle(hKV);
		}
	}
	else if (action == MenuAction_End)
		CloseHandle(menu);
}

public OnConfigsExecuted() {
	CreateTimer(GetConVarFloat(g_hCVRefreshInterval), OnTimerRefreshServers, _, TIMER_REPEAT|TIMER_FLAG_NO_MAPCHANGE);
	if (GetConVarFloat(g_hCVAdvertInterval) != 0.0)
		g_hAdTimer = CreateTimer(GetConVarFloat(g_hCVAdvertInterval), OnTimerAdvert, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
	else
		g_hAdTimer = INVALID_HANDLE;
}

public Action:OnTimerRefreshServers(Handle:timer) {
	RefreshServerList();
	return Plugin_Continue;
}

public Action:OnTimerAdvert(Handle:timer) {
	if (GetArraySize(g_hServers) == 0)
		return Plugin_Continue;
	if (iAdTimerNextSID >= GetArraySize(g_hServers))
		iAdTimerNextSID = 0;
	
	new Handle:hServerTrie = GetArrayCell(g_hServers, iAdTimerNextSID);
	new String:sIP[255], iPort, String:sName[MAX_STR_LEN], String:sMap[MAX_STR_LEN],
	iPlayers, iMaxPlayers;

	GetTrieString(hServerTrie, "ip", sIP, sizeof(sIP));
	GetTrieValue(hServerTrie, "port", iPort);
	GetTrieString(hServerTrie, "name", sName, sizeof(sName));
	GetTrieString(hServerTrie, "map", sMap, sizeof(sMap));
	GetTrieValue(hServerTrie, "players", iPlayers);
	GetTrieValue(hServerTrie, "maxplayers", iMaxPlayers);
	
	CPrintToChatAll("{green}[SM]{lightgreen} Type {green}/servers{lightgreen} to visit our other servers!");
	CPrintToChatAll("{lightgreen}%s {green}-{lightgreen} %s {green}({lightgreen}%d{green}/{lightgreen}%d{green})", sName, sMap, iPlayers, iMaxPlayers);
	
	iAdTimerNextSID++;
	return Plugin_Continue;
}

public InitDatabase() {
	if (g_hDatabase != INVALID_HANDLE)
		return;
	
	if (SQL_CheckConfig("sourcebans"))
		SQL_TConnect(OnDatabaseConnect, "sourcebans");
	else
		SetFailState("[REDIRECT] Unable to find database configuration");
}

public OnDatabaseConnect(Handle:owner, Handle:hndl, const String:error[], any:data){
	if (hndl == INVALID_HANDLE)
		SetFailState("[REDIRECT] Unable to connect to the database");
	else {
		g_hDatabase = hndl;
		RefreshServerList();
	}
}

public ClearServerList() {
	for (new i = 0; i < GetArraySize(g_hServers); i++)
		CloseHandle(GetArrayCell(g_hServers, i));
	ClearArray(g_hServers);
}

public RemoveSocketFromArray(Handle:sock) {
	for (new i = 0; i < GetArraySize(g_hServerSockets); i++)
		if (GetArrayCell(g_hServerSockets, i) == sock)
			SetArrayCell(g_hServerSockets, i, INVALID_HANDLE);
}

public CleanUpSockets() {
	for (new i = 0; i < GetArraySize(g_hServerSockets); i++) {
		new Handle:hTmp = GetArrayCell(g_hServerSockets, i);
		if (hTmp != INVALID_HANDLE)
			CloseHandle(hTmp);
	}
	ClearArray(g_hServerSockets);
}

public RefreshServerList() {
	if (g_hDatabase == INVALID_HANDLE)
		return;
	
	new String:sQuery[255], String:sDBPrefix[32];
	GetConVarString(g_hCVPrefix, sDBPrefix, sizeof(sDBPrefix));
	Format(sQuery, sizeof(sQuery), "SELECT `ip`, `port` FROM `%s_servers` WHERE `enabled` = '1' AND `modid` = '13';", sDBPrefix);
	SQL_TQuery(g_hDatabase, RefreshServerListDBReply, sQuery);
}

public RefreshServerListDBReply(Handle:database, Handle:hndl, String:error[], any:data) {
	if (hndl == INVALID_HANDLE || strlen(error) > 0)
		return;
	
	ClearServerList();
	CleanUpSockets();
	while (SQL_FetchRow(hndl)) {
		new String:sIP[32], iPort;
		SQL_FetchString(hndl, 0, sIP, sizeof(sIP));
		iPort = SQL_FetchInt(hndl, 1);
		new Handle:hServerTrie = CreateTrie();
		PushArrayCell(g_hServers, hServerTrie);
		SetTrieString(hServerTrie, "ip", sIP);
		SetTrieValue(hServerTrie, "port", iPort);
		SetTrieString(hServerTrie, "name", "");
		SetTrieString(hServerTrie, "map", "");
		SetTrieValue(hServerTrie, "players", -1);
		SetTrieValue(hServerTrie, "maxplayers", -1);
		new Handle:hSocket = SocketCreate(SOCKET_UDP, OnSocketError);
		PushArrayCell(g_hServerSockets, hSocket);
		SocketSetArg(hSocket, hServerTrie);
		SocketConnect(hSocket, OnSocketConnected, OnSocketReceive, OnSocketDisconnect, sIP, iPort);
	}
	
	CreateTimer(SOCKET_TIMEOUT, OnTimerCleanUpSockets);
}

public Action:OnTimerCleanUpSockets(Handle:timer) {
	CleanUpSockets();
	return Plugin_Stop;
}

public OnSocketConnected(Handle:sock, any:hServer) {
	decl String:sRequest[25];
	Format(sRequest, sizeof(sRequest), "%s", "\xFF\xFF\xFF\xFF\x54Source Engine Query");
	SocketSend(sock, sRequest, sizeof(sRequest));
}

String:GetString(String:receivedData[], dataSize, offset) {
	decl String:serverStr[MAX_STR_LEN] = "";
	new j = 0;
	for (new i = offset; i < dataSize; i++) {
		serverStr[j] = receivedData[i];
		j++;
		if (receivedData[i] == '\x0')
			break;
	}
	return serverStr;
}

public OnSocketReceive(Handle:sock, String:receivedData[], const dataSize, any:hServer) {
	new String:tmp[MAX_STR_LEN], String:sName[MAX_STR_LEN], String:sMap[MAX_STR_LEN],
	iPlayers, iMaxPlayers;
	new offset = 6;
	sName = GetString(receivedData, dataSize, offset);
	offset += strlen(sName) + 1;
	sMap = GetString(receivedData, dataSize, offset);
	offset += strlen(sMap) + 1;
	tmp = GetString(receivedData, dataSize, offset);
	offset += strlen(tmp) + 1;
	tmp = GetString(receivedData, dataSize, offset);
	offset += strlen(tmp) + 1;
	offset += 2;
	iPlayers = receivedData[offset++];
	iMaxPlayers = receivedData[offset++];
	
	TrimString(sName);
	SetTrieString(hServer, "name", sName);
	SetTrieString(hServer, "map", sMap);
	SetTrieValue(hServer, "players", iPlayers);
	SetTrieValue(hServer, "maxplayers", iMaxPlayers);
	
	RemoveSocketFromArray(sock);
	CloseHandle(sock);
}

public OnSocketDisconnect(Handle:sock, any:hServer) {
	RemoveSocketFromArray(sock);
	CloseHandle(sock);
}

public OnSocketError(Handle:sock, const errorType, const errorNum, any:hServer) {
	RemoveSocketFromArray(sock);
	CloseHandle(sock);
}