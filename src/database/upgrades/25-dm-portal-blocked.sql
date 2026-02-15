-- v25: Store whether DM portal is blocked
ALTER TABLE portal ADD COLUMN blocked BOOLEAN NOT NULL DEFAULT false;
