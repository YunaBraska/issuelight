CREATE DATABASE IF NOT EXISTS icingadb CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;
CREATE USER IF NOT EXISTS 'icingadb'@'%' IDENTIFIED BY 'issuelight-lab-db';
GRANT ALL PRIVILEGES ON icingadb.* TO 'icingadb'@'%';

CREATE DATABASE IF NOT EXISTS icingaweb2 CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;
CREATE USER IF NOT EXISTS 'icingaweb2'@'%' IDENTIFIED BY 'issuelight-lab-db';
GRANT ALL PRIVILEGES ON icingaweb2.* TO 'icingaweb2'@'%';

FLUSH PRIVILEGES;
