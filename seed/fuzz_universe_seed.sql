-- Curated ground-truth universe (real global tickers, edge cases) for the admin
-- SnapTrade resolution fuzzer. DATA ONLY — the table itself is created by Flyway
-- migration V20260627120000__CreateFuzzTestUniverse.sql. Run by hand on a local/dev
-- DB after migrations have applied:
--   psql "$DATABASE_URL" -f infra-and-docs/seed/fuzz_universe_seed.sql
-- Version-controlled so the curated "formats we know break us" list is reproducible,
-- not laptop-local. Re-runnable: truncate first (hard cap per fuzz run is 50).
TRUNCATE fuzz_test_universe;
INSERT INTO fuzz_test_universe (ticker, exchange_code, mic_code, currency, asset_name) VALUES
  -- US class shares (dot/dash separator class — BRK.B vs BRK-B)
  ('BRK.B',      'NYSE',  'XNYS', 'USD', 'Berkshire Hathaway Inc Class B'),
  ('BF.B',       'NYSE',  'XNYS', 'USD', 'Brown-Forman Corp Class B'),
  ('BF.A',       'NYSE',  'XNYS', 'USD', 'Brown-Forman Corp Class A'),
  ('LEN.B',      'NYSE',  'XNYS', 'USD', 'Lennar Corp Class B'),
  ('HEI.A',      'NYSE',  'XNYS', 'USD', 'HEICO Corp Class A'),
  ('GOOG',       'NASDAQ','XNAS', 'USD', 'Alphabet Inc Class C'),
  ('GOOGL',      'NASDAQ','XNAS', 'USD', 'Alphabet Inc Class A'),
  -- Plain US large caps (control rows — should resolve cleanly)
  ('AAPL',       'NASDAQ','XNAS', 'USD', 'Apple Inc'),
  ('MSFT',       'NASDAQ','XNAS', 'USD', 'Microsoft Corp'),
  ('JPM',        'NYSE',  'XNYS', 'USD', 'JPMorgan Chase & Co'),
  -- Cross-listed ETF: same ticker, two venues/currencies -> Step B2 ccy gating
  ('SPYD',       'ARCA',  'ARCX', 'USD', 'SPDR Portfolio S&P 500 High Div'),
  ('SPYD',       'XETRA', 'XETR', 'EUR', 'SPDR S&P 500 High Div (Xetra)'),
  ('IUSA',       'XETRA', 'XETR', 'EUR', 'iShares Core S&P 500 UCITS (Xetra)'),
  ('IUSA',       'LSE',   'XLON', 'USD', 'iShares Core S&P 500 UCITS (LSE USD)'),
  ('VWRL',       'LSE',   'XLON', 'GBP', 'Vanguard FTSE All-World UCITS (LSE)'),
  ('VWRL',       'AEX',   'XAMS', 'EUR', 'Vanguard FTSE All-World UCITS (Amsterdam)'),
  -- US-listed ETFs (ARCA-heavy, FIGI-drop targets)
  ('VOO',        'ARCA',  'ARCX', 'USD', 'Vanguard S&P 500 ETF'),
  ('SCHD',       'ARCA',  'ARCX', 'USD', 'Schwab US Dividend Equity ETF'),
  ('QQQ',        'NASDAQ','XNAS', 'USD', 'Invesco QQQ Trust'),
  -- Indian series-suffix targets (-BZ / -BE / -RR / -IF strip + classify)
  ('INFY',       'NSE',   'XNSE', 'INR', 'Infosys Ltd'),
  ('TCS',        'NSE',   'XNSE', 'INR', 'Tata Consultancy Services Ltd'),
  ('RELIANCE',   'NSE',   'XNSE', 'INR', 'Reliance Industries Ltd'),
  ('RAJESHEXPO', 'NSE',   'XNSE', 'INR', 'Rajesh Exports Ltd'),
  ('HDFCBANK',   'NSE',   'XNSE', 'INR', 'HDFC Bank Ltd'),
  ('YESBANK',    'NSE',   'XNSE', 'INR', 'Yes Bank Ltd'),
  ('IDEA',       'NSE',   'XNSE', 'INR', 'Vodafone Idea Ltd'),
  -- Indian BSE leg (same security, different exchange code)
  ('INFY',       'BSE',   'XBOM', 'INR', 'Infosys Ltd (BSE)'),
  ('RELIANCE',   'BSE',   'XBOM', 'INR', 'Reliance Industries Ltd (BSE)'),
  -- Indian REITs / InvITs (normalize + classify edge)
  ('EMBASSY',    'NSE',   'XNSE', 'INR', 'Embassy Office Parks REIT'),
  ('MINDSPACE',  'NSE',   'XNSE', 'INR', 'Mindspace Business Parks REIT'),
  ('POWERGRID',  'NSE',   'XNSE', 'INR', 'PowerGrid Infrastructure InvIT'),
  -- European single-listings (Bloomberg exch-code mapping exercise)
  ('SAP',        'XETRA', 'XETR', 'EUR', 'SAP SE'),
  ('ASML',       'AEX',   'XAMS', 'EUR', 'ASML Holding NV'),
  ('SHEL',       'LSE',   'XLON', 'GBP', 'Shell plc'),
  ('AZN',        'LSE',   'XLON', 'GBP', 'AstraZeneca plc'),
  -- Canadian dual-class / TSX (non-US separator + CAD ccy chaos target)
  ('RCI.B',      'TSX',   'XTSE', 'CAD', 'Rogers Communications Inc Class B'),
  ('BBD.B',      'TSX',   'XTSE', 'CAD', 'Bombardier Inc Class B');
