module app

fn test_connect_enforces_foreign_keys() {
	db := connect(Config{})!
	rows := db.exec('PRAGMA foreign_keys')!
	assert rows[0].vals == ['1']
}
