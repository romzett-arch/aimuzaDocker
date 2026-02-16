UPDATE settings SET value = '300' WHERE key = 'deposit_price_blockchain';
INSERT INTO settings (key, value) SELECT 'deposit_price_blockchain', '300' WHERE NOT EXISTS (SELECT 1 FROM settings WHERE key = 'deposit_price_blockchain');
