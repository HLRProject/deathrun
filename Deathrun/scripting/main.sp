#include <sourcemod>
#include <sdktools>

//Player stats:
int g_Frags[MAXPLAYERS + 1], g_Deaths[MAXPLAYERS + 1], g_Playtime[MAXPLAYERS + 1], g_PlayerID[MAXPLAYERS + 1];

int g_PlayerTeam[MAXPLAYERS + 1] = {1, ...};
int g_BlueScore, g_RedScore;

bool g_CheckTeams;
bool g_Live;

//Trapper queue:
ArrayList g_BlueQueue;

//Database Functionality:
ArrayList g_DirtyList;
Database g_DB;

//Server CVars:
ConVar g_cvBlueRatio; //Maximum ratio of Red to Blue (Runners vs Trappers). Default: 3 to 1
ConVar g_cvBlueQueue; //Enable a queue system for joining Trappers when team is full.

public void OnMapStart()
{
	g_Live = false;
	g_CheckTeams = false;
}

public void OnPluginStart()
{
	g_Live = false;
	g_CheckTeams = false;

	//CVars:
	g_cvBlueRatio = CreateConVar("dr_blueratio", "3", "Maximum ratio of red to blue (runners vs trappers)", FCVAR_NOTIFY);
	g_cvBlueRatio.AddChangeHook(OnRatioChanged);

	g_cvBlueQueue = CreateConVar("dr_bluequeue", "1", "Should there be a queue system to join blue team?", FCVAR_NOTIFY);
	g_cvBlueQueue.AddChangeHook(OnQueueChanged);

	AutoExecConfig(true);

	//Events:
	HookEvent("round_start", Event_RoundStart);
	HookEvent("teamplay_round_start", Event_RoundStart);
	HookEvent("player_spawn", Event_PlayerSpawn, EventHookMode_Post);
	HookEvent("player_death", Event_PlayerDeath, EventHookMode_Post);
	HookEvent("player_team", Event_PlayerTeam, EventHookMode_Pre);

	//Commands:
	AddCommandListener(Listen_JoinTeam, "jointeam");
	AddCommandListener(Listen_JoinTeam, "spectate");

	RegConsoleCmd("sm_team", Command_TeamMenu, "Select a team via the team menu");
	RegConsoleCmd("sm_teams", Command_TeamMenu, "Select a team via the team menu");
	RegConsoleCmd("sm_join", Command_TeamMenu, "Select a team via the team menu");

	RegConsoleCmd("sm_queue", Command_BlueQueue, "Show the current queue size and/or your position");
	

	RegAdminCmd("sm_switch", Command_SwitchPlayer, ADMFLAG_GENERIC, "Forcefully switch a player's team");

	RegServerCmd("sm_debuglist", Command_DebugList, "Print out all stored queries in the dirty list");
	RegServerCmd("sm_debugqueue", Command_DebugQueue, "Print out all current players in the blue queue");

	g_DirtyList = new ArrayList(256);
	Database.Connect(Database_Connect, "deathrun");

	if(g_cvBlueQueue.BoolValue) g_BlueQueue = new ArrayList();
}

public Action Command_DebugQueue(int args)
{	
	PrintToServer("Debugging g_BlueQueue:");
	for(int i = 0; i < g_BlueQueue.Length; i++)
	{
		int serial = g_BlueQueue.Get(i);
		PrintToServer("%i: %N <uid: %i, serial: %i>", i + 1, GetClientFromSerial(serial), GetClientUserId(GetClientFromSerial(serial)), serial);
	}

	return Plugin_Handled;
}

public Action Command_BlueQueue(int client, int args)
{
	if(client == 0)
	{
		ReplyToCommand(client, "???");
		return Plugin_Handled;
	}

	int idx = g_BlueQueue.FindValue(GetClientSerial(client));

	//Not in queue:
	if(idx == -1)
	{
		ReplyToCommand(client, "[DR] The current queue for Trappers is at %i players.", g_BlueQueue.Length == 0 ? g_BlueQueue.Length : g_BlueQueue.Length + 1);
		return Plugin_Handled;
	}

	ReplyToCommand(client, "[DR] You are in the trapper queue. Current position: %i of %i", idx + 1, g_BlueQueue.Length);
	return Plugin_Handled;
}

public Action Command_DebugList(int args)
{
	PrintToServer("Displaying all queries stored in the debug list:");

	//Create file for debug:
	char path[PLATFORM_MAX_PATH]; BuildPath(Path_SM, path, sizeof(path), "data/deathrun/debug");
	char timeFmt[32]; FormatTime(timeFmt, sizeof(timeFmt), "%H-%M_%m-%d-%Y", GetTime());
	char fileName[PLATFORM_MAX_PATH]; BuildPath(Path_SM, fileName, sizeof(fileName), "data/deathrun/debug/dirtylist_debug-%s.txt", timeFmt);

	//Attempt to create directory:
	if(!DirExists(path))
	{
		if(!CreateDirectory(path, 777))
		{
			ThrowError("[DR] Error creating directory: %s - Manually create directory and try again.");
			return Plugin_Handled;
		}
	}

	//Open File:
	File f = OpenFile(fileName, "a+");
	f.WriteLine("Displaying all queries stored in the debug list:");

	for(int i = 0; i < g_DirtyList.Length; i++)
	{
		//Retrive query:
		char query[256]; g_DirtyList.GetString(i, query, sizeof(query));
		PrintToServer("%i: %s", i, query);

		//Write to file:
		f.WriteLine(query);
	}

	delete f;
	return Plugin_Handled
}

public Action Timer_RetryConnection(Handle timer)
{
	Database.Connect(Database_Connect, "deathrun", 1);
	return Plugin_Handled;
}

public Action Timer_RetryLoadPlayer(Handle timer, any data)
{
	int client = GetClientFromSerial(data);

	char steamid[64]; GetClientAuthId(client, AuthId_SteamID64, steamid, sizeof(steamid));
	char query[256]; Format(query, sizeof(query), "SELECT * FROM deathrun_player_data WHERE steam_id = '%s';", steamid);
	g_DB.Query(Database_LoadPlayer, query, data);
}

void Database_Connect(Database db, const char[] error, any data)
{
	if(db == null)
	{
		if(data != 1)
		{
			ThrowError("Database_Connect Retry Error: %s\n[DR] Retrying connection in 5.0 seconds...", error);
			CreateTimer(5.0, Timer_RetryConnection);
			return;
		}

		ThrowError("Database_Connect Error: %s\n[DR] Retrying connection in 5.0 seconds...", error);
		CreateTimer(5.0, Timer_RetryConnection);
		return;

	}

	PrintToServer("[DR] Database connection successful");
	g_DB = db;
	CreateTimer(300.0, Timer_CleanList, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);

	//Connection was flawed initially, try to load any players now:
	if(data == 1)
	{
		PrintToServer("[DR] Database connection successful (after error)");
		for(int i = 1; i <= MaxClients; i++)
		{
			if(IsClientConnected(i) && IsClientAuthorized(i))
			{
				char steamid[64]; GetClientAuthId(i, AuthId_SteamID64, steamid, sizeof(steamid));
				char query[256]; Format(query, sizeof(query), "SELECT * FROM deathrun_player_data WHERE steam_id = '%s';", steamid);
				g_DB.Query(Database_LoadPlayer, query, GetClientSerial(i));
			}
		}
	}
}

void Database_GenericQuery(Database db, DBResultSet results, const char[] error, any data)
{
	if(db == null)
	{
		ThrowError("Database_GenericQuery DB Error: %s", error);
	}

	if(results == null)
	{
		ThrowError("Database_GenericQuery Error: %s", error);
	}
}

public Action Timer_CleanList(Handle timer)
{
	for(int i = 0; i < g_DirtyList.Length; i++)
	{
		//The mentality here is instead of having random queries be fired at random intervals,
		//we store them in an arraylist and fire them all off every 5 minutes
		//No transactions due to integrity being variable, and I'd rather see one fail and 500 succeed versus all 501 fail
		char query[256];
		g_DirtyList.GetString(i, query, sizeof(query));
		g_DB.Query(Database_GenericQuery, query);
	}

	g_DirtyList.Clear();
}

public Action Command_SwitchPlayer(int client, int args)
{
	if(args != 1)
	{
		ReplyToCommand(client, "[DR] Invalid Syntax: sm_switch <player>");
		return Plugin_Handled;
	}

	//Find a target:
	char szTarget[MAX_NAME_LENGTH]; GetCmdArgString(szTarget, sizeof(szTarget));
	int target = FindTarget(client, szTarget, false, true);
	if(target == -1) //Invalid target?:
	{
		ReplyToCommand(client, "[DR] Invalid Target: %s", szTarget);
		return Plugin_Handled;
	}

	ChangeClientTeam(target, 3);
	ReplyToCommand(client, "[DR] Force switched %N's team to Runners.", target);
	PrintToChat(target, "[DR] Admin %N switched your team to Runners.", client);
	return Plugin_Handled;
}

public Action Command_TeamMenu(int client, int args)
{
	DisplayTeamMenu(client);
	PrintToChat(client, "[DR] Press <escape> to open the team menu.");
	return Plugin_Handled;
}

public void OnClientPutInServer(int client)
{
	g_PlayerTeam[client] = 1;
	if(IsClientInGame(client))
	{
		//Move to spectator:
		ChangeClientTeam(client, 1);
		DisplayTeamMenu(client);
		PrintToChat(client, "[DR] Press <escape> to open the team menu.");
	}
}

public void OnClientAuthorized(int client)
{
	char steamid[64]; GetClientAuthId(client, AuthId_SteamID64, steamid, sizeof(steamid));
	char query[256]; Format(query, sizeof(query), "SELECT * FROM deathrun_player_data WHERE steam_id = '%s';", steamid);
	g_DB.Query(Database_LoadPlayer, query, GetClientSerial(client));
}

public void Database_LoadPlayer(Database db, DBResultSet results, const char[] error, any data)
{
	if(db == null)
	{
		ThrowError("[DR] Database Error in Database_LoadPlayer: %s]", error);
		return;
	}

	//Handle if it's a retry and the client has left or gone invalid for any reason:
	int client = GetClientFromSerial(data);
	if(!IsClientConnected(client) || !IsClientInGame(client) || !IsClientAuthorized(client)) return;

	//New player? Insert their data:
	if(!results.FetchRow())
	{
		char steamid[64]; GetClientAuthId(client, AuthId_SteamID64, steamid, sizeof(steamid));
		char query[256]; Format(query, sizeof(query), "INSERT INTO deathrun_player_data (steam_id) VALUES ('%s');", steamid);
		g_DB.Query(Database_GenericQuery, query);
		return;
	}

	//Existing player, load data:
	int fragCol, deathCol, playedCol, idCol;
	results.FieldNameToNum("frags", fragCol);
	results.FieldNameToNum("deaths", deathCol);
	results.FieldNameToNum("played", playedCol);
	results.FieldNameToNum("player_id", idCol);

	g_Frags[client] = results.FetchInt(fragCol);
	g_Deaths[client] = results.FetchInt(deathCol);
	g_Playtime[client] = results.FetchInt(playedCol);
	g_PlayerID[client] = results.FetchInt(idCol);
}

public void OnClientDisconnect(int client)
{
	//Check and see if they affect queue at all:
	if(g_cvBlueQueue.BoolValue)
	{
		//They are leaving blue, pop one in place:
		if(g_PlayerTeam[client] == 2)
		{
			int player;
			while(player <= 0)
			{
				player = GetClientFromSerial(g_BlueQueue.Get(0));
				if(g_PlayerTeam[player] == 2) player = -1;
				if(!IsClientConnected(player) || !IsClientInGame(player)) player = -1;

				PrintToChat(player, "[DR] You will be moved to Trappers next round.");
				g_PlayerTeam[player] = 2;
				g_BlueQueue.Erase(0);
			}

			//Notify all other players in the queue their position has moved:
			for(int i = 0; i < g_BlueQueue.Length; i++)
			{
				int c = GetClientFromSerial(g_BlueQueue.Get(i));
				PrintToChat(c, "[DR] Your current position in the Trapper queue is: #%i", i);
			}
		}
		else
		{
			int idx = g_BlueQueue.FindValue(GetClientSerial(client));
			//They are in the queue, remove them:
			if(idx > -1)
			{
				g_BlueQueue.Erase(idx);

				//Notify all other players in the queue their position has moved:
				for(int i = 0; i < g_BlueQueue.Length; i++)
				{
					int c = GetClientFromSerial(g_BlueQueue.Get(i));
					PrintToChat(c, "[DR] Your current position in the Trapper queue is: #%i", i);
				}
			}
		}
	}
	//Add data query to the dirty list:
	char steamid[64]; GetClientAuthId(client, AuthId_SteamID64, steamid, sizeof(steamid));
	char query[256]; Format(query, sizeof(query), "UPDATE deathrun_player_data SET time_played = time_played + %i WHERE steam_id = '%s';", RoundToFloor(GetClientTime(client)), steamid);
	g_DirtyList.PushString(query);

	//Signal to check team balance:
	g_CheckTeams = true;
	g_PlayerTeam[client] = 1; //Spectator
}

void DisplayTeamMenu(int client)
{
	Menu menu = new Menu(MHandler_TeamMenu)
	menu.SetTitle("Select a Team:");
	menu.AddItem("1", "[Spectator]");
	menu.AddItem("2", "[Trapper]");
	menu.AddItem("3", "[Runner]");

	//If theyre in queue, display an option to leave it:
	if(g_BlueQueue.FindValue(GetClientSerial(client)) > -1)	menu.AddItem("6", "[Leave Trapper Queue]");
	menu.Display(client, 30);
}

public int MHandler_TeamMenu(Menu m, MenuAction action, int client, int selection)
{
	switch(action)
	{
		case MenuAction_Select:
		{
			char item[32];
			m.GetItem(selection, item, sizeof(item));
			switch(StringToInt(item))
			{
				//Spectator:
				case 1: 
				{
					ChangeClientTeam(client, 1);
					PrintToChat(client, "[DR] You have moved to Spectators.");
					g_PlayerTeam[client] = 1;
				}

				//Trapper:
				case 2:
				{
					//Get current team ratio:
					int ratio;
					int blueCount, redCount;

					//Count players in each team:
					for(int i = 1; i <= MaxClients; i++)
					{
						if(g_PlayerTeam[i] == 2) blueCount++;
						else if(g_PlayerTeam[i] == 3) redCount++;
					}

					//If less than 2 Trappers, let a player go on team (bypass ratio):
					if(blueCount < 2)
					{
						ChangeClientTeam(client, 2);
						g_PlayerTeam[client] = 2;

						if(g_Live)
						{
							PrintToChat(client, "[DR] You will be moved to Trappers next round.");
							return;
						}

						PrintToChat(client, "[DR] You have moved to Trappers.");
						DispatchSpawn(client);
						return;
					}

					ratio = redCount / blueCount;
					if(ratio <= g_cvBlueRatio.IntValue)
					{
						ChangeClientTeam(client, 2);
						g_PlayerTeam[client] = 2;

						if(g_Live)
						{
							PrintToChat(client, "[DR] You will be moved to Trappers next round.");
							return;
						}

						PrintToChat(client, "[DR] You have moved to Trappers.");
						DispatchSpawn(client);
					}
					else
					{
						//If queue is enabled, place them in the queue:
						if(g_cvBlueQueue.BoolValue)
						{
							int idx = g_BlueQueue.Push(GetClientSerial(client));
							PrintToChat(client, "[DR] The Trapper team is currently full. You have been placed in the queue at position: #%i", idx);
							return;
						}

						PrintToChat(client, "[DR] The Trappers team is currently full. (Maximum 1 to %i Ratio.)", g_cvBlueRatio.IntValue);
					}
				}

				//Runner:
				case 3:
				{
					//Check if they are leaving blue and if there is a queue:
					if(g_cvBlueQueue.BoolValue)
					{
						//They are leaving blue, pop one in place:
						if(g_PlayerTeam[client] == 2)
						{
							int player;
							while(player <= 0)
							{
								player = GetClientFromSerial(g_BlueQueue.Get(0));
								if(g_PlayerTeam[player] == 2) player = -1;
								if(!IsClientConnected(player) || !IsClientInGame(player)) player = -1;

								PrintToChat(player, "[DR] You will be moved to Trappers next round.");
								g_PlayerTeam[player] = 2;
								g_BlueQueue.Erase(0);
							}

							//Notify all other players in the queue their position has moved:
							for(int i = 0; i < g_BlueQueue.Length; i++)
							{
								int c = GetClientFromSerial(g_BlueQueue.Get(i));
								PrintToChat(c, "[DR] Your current position in the Trapper queue is: #%i", i);
							}
						}
					}

					//Finally manage the person who is moving teams:
					ChangeClientTeam(client, 3);
					g_PlayerTeam[client] = 3;

					if(g_Live)
					{
						PrintToChat(client, "[DR] You will be moved to Runners next round.");
						return;
					}

					PrintToChat(client, "[DR] You have moved to Runners.");
					DispatchSpawn(client);
				}


				//Leave Trapper Queue:
				case 6:
				{
					int serial = GetClientSerial(client);
					int idx = g_BlueQueue.FindValue(serial);

					//Error handling, although this should never happen:
					if(idx == -1)
					{
						ThrowError("[DR] Error removing user %N <uid: %i, serial: %i> from blue queue.", client, GetClientUserId(client), serial);
						PrintToChat(client, "[DR] There was an error removing you from the queue, let an admin know.");
						return;
					}

					g_BlueQueue.Erase(idx);
					PrintToChat(client, "[DR] You have been removed from the Trapper queue at position: #%i", idx);
				}

				default: return;
			}
		}

		case MenuAction_End: delete m;
	}
}

public Action Listen_JoinTeam(int client, const char[] command, int argc)
{
	DisplayTeamMenu(client);
	PrintToChat(client, "[DR] Press <escape> to open the team menu.");
	return Plugin_Handled;
}

public void RemoveWeapons(int client)
{
	//4 bytes each, take i and add 4 (0 + 4 = 4, i + 4 = 8, etc.)
	for (int i = 0; i < 48; i++) 
	{
		int weapon = GetEntPropEnt(client, Prop_Data, "m_hMyWeapons", i);
		if (!IsValidEntity(weapon)) continue;
		if (RemovePlayerItem(client, weapon)) AcceptEntityInput(weapon, "Kill");
	}
	GivePlayerItem(client, "weapon_crowbar");
}

public Action Event_PlayerTeam(Event e, const char[] eventName, bool noBroadcast)
{
	e.SetBool("silent", true);
}

public Action Event_PlayerSpawn(Event e, const char[] eventName, bool noBroadcast)
{
	//Remove weapons + give crowbar
	int client = GetClientOfUserId(e.GetInt("userid"));
	RequestFrame(RemoveWeapons, client);
}

public Action Event_PlayerDeath(Event e, const char[] eventName, bool noBroadcast)
{
	//Move to spectator on death:
	int client = GetClientOfUserId(e.GetInt("userid"));
	if(g_Live) ChangeClientTeam(client, 1);

	int attacker = GetClientOfUserId(e.GetInt("attacker"));

	//Push query data to dirty list:
	if(client != attacker)
	{
		//Give attacker + 1 frag:
		char steamid[64]; GetClientAuthId(attacker, AuthId_SteamID64, steamid, sizeof(steamid));
		char query[256]; Format(query, sizeof(query), "UPDATE deathrun_player_data SET frags = frags + 1 WHERE steam_id = '%s';", steamid);
		g_DirtyList.PushString(query);

		//Give client + 1 death:
		GetClientAuthId(client, AuthId_SteamID64, steamid, sizeof(steamid));
		Format(query, sizeof(query), "UPDATE deathrun_player_data SET deaths = deaths + 1 WHERE steam_id = '%s';", steamid);
		g_DirtyList.PushString(query);
	}

	//Check teams to see if we have a winning team:
	int redCount, blueCount;
	for(int i = 1; i <= MaxClients; i++)
	{
		if(IsClientConnected(i) && IsClientInGame(i) && IsPlayerAlive(i))
		{
			if(g_PlayerTeam[i] == 2) blueCount++;
			else if(g_PlayerTeam[i] == 3) redCount++;
		}
	}

	if(g_Live)
	{
		//Trapper Win:
		if(redCount == 0)
		{
			PrintCenterTextAll("Trappers Victory!");
			g_BlueScore++;

			CreateTimer(5.0, Timer_RestartRound);
		}

		//Runner Win:
		else if(blueCount == 0)
		{
			PrintCenterTextAll("Runners Victory!");
			g_RedScore++;

			CreateTimer(5.0, Timer_RestartRound);
		}
	}
}

public Action Timer_RestartRound(Handle timer)
{	
	//Count players on teams:
	int ratio; 
	if(g_CheckTeams)
	{
		int redCount, blueCount;
		for(int i = 1; i <= MaxClients; i++)
		{
			if(g_PlayerTeam[i] == 2) blueCount++;
			else if(g_PlayerTeam[i] == 3) redCount++;
		}
		ratio = redCount / blueCount;
	}
	
	//Do this all on a global scale:
	int highest[2];
	for(int i = 1; i <= MaxClients; i++)
	{
		if(!IsClientConnected(i) || !IsClientInGame(i)) continue;

		//Check if blue needs to be adjusted:
		if(g_CheckTeams)
		{
			//Blue has too many players, find who the oldest blue is:
			if(ratio < g_cvBlueRatio.IntValue)
			{
				if(g_PlayerTeam[i] == 2)
				{
					if(highest[0] < RoundToFloor(GetClientTime(i)))
					{
						highest[0] = RoundToFloor(GetClientTime(i));
						highest[1] = GetClientSerial(i);
					}
				}
			}
		}

		//Switch players from spectate to their respective teams:
		if(IsClientObserver(i))
		{
			PrintToServer("Observer: %N\nTeam: %i", i, g_PlayerTeam[i]);
			ChangeClientTeam(i, g_PlayerTeam[i]);
		}
	}

	//Finally move the oldest blue player:
	if(g_CheckTeams)
	{
		int client = GetClientFromSerial(highest[1]);
		ChangeClientTeam(client, 3);
		PrintToChat(client, "[DR] You have been moved to Runners as you have been a Trapper the longest time.");
	}

	ServerCommand("mp_restartgame 1");
}

public Action Event_RoundStart(Event e, const char[] eventName, bool noBroadcast)
{
	for(int i = 1; i <= MaxClients; i++)
	{
		if(IsClientConnected(i) && IsClientInGame(i))
		{
			ChangeClientTeam(i, g_PlayerTeam[i]);
			DispatchSpawn(i);
		}
	}
}

public void OnRatioChanged(ConVar cvar, const char[] oldVal, const char[] newVal)
{
	if(StringToInt(oldVal) > StringToInt(newVal)) return;

	//Do math and switch oldest blue team player to red:
	int highest[2];
	for(int i = 1; i <= MaxClients; i++)
	{
		if(GetClientTeam(i) == 2)
		{
			if(highest[0] < RoundToFloor(GetClientTime(i)))
			{
				highest[0] = RoundToFloor(GetClientTime(i));
				highest[1] = GetClientSerial(i);
			}
		}
	}

	int player = GetClientFromSerial(highest[1]);
	ChangeClientTeam(player, 3);
	DispatchSpawn(player);
}

public void OnQueueChanged(ConVar cvar, const char[] oldVal, const char[] newVal)
{
	bool enable = view_as<bool>(StringToInt(newVal));

	if(enable) g_BlueQueue = new ArrayList();
	else delete g_BlueQueue;
}

public Plugin myinfo =
{
	name = "HLR Deathrun Project",
	author = "",
	description = "a deathrun game mode",
	version = "0.1.15",
	url = "https://sourcemod.net"
};