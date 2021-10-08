CREATE TABLE IF NOT EXISTS deathrun_player_data (
	steam_id VARCHAR(64) NOT NULL,
	player_id INT NOT NULL AUTO_INCREMENT,
	frags INT NOT NULL DEFAULT 0,
	deaths INT NOT NULL DEFAULT 0,
	played INT NOT NULL DEFAULT 0,
	PRIMARY KEY(player_id, steam_id)
	KEY(steam_id)
);