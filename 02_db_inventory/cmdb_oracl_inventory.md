# Oracle Enterprise Manager to ServiceNow CMDB Export Script
Here's a Python script that queries multiple OEM servers via EMCLI and exports Oracle instance information to JSON for ServiceNow CMDB ingestion.

## Prerequisites
Before running, ensure:

EMCLI is installed and configured on the host
You have OEM credentials with appropriate read permissions
Python 3.7+ is installed


## Configuration File Example
Create a config.json file:

{
  "oem_servers": [
    {
      "name": "OEM-PROD-01",
      "url": "https://oem-prod-01.example.com:7803/em",
      "username": "oem_reader",
      "password": "your_password_here",
      "trust_all_certs": true
    },
    {
      "name": "OEM-PROD-02",
      "url": "https://oem-prod-02.example.com:7803/em",
      "username": "oem_reader",
      "password": "your_password_here",
      "trust_all_certs": true
    },
    {
      "name": "OEM-DR",
      "url": "https://oem-dr.example.com:7803/em",
      "username": "oem_reader",
      "password": "your_password_here",
      "trust_all_certs": false
    }
  ]
}


## Usage
### Basic usage
python oem_discovery.py -c config.json
### With custom output directory and verbose logging
python oem_discovery.py -c config.json -o /data/cmdb_exports -v
### Specify EMCLI path and parallelism
python oem_discovery.py -c config.json --emcli-path /opt/oracle/emcli/emcli --parallel 5


## Output JSON Structure
The script generates a file like oracle_instances_20260427_143022.json:

{
  "source": "OEM Discovery",
  "export_timestamp": "2026-04-27T14:30:22.123456+00:00",
  "record_count": 42,
  "records": [
    {
      "name": "PRODDB01",
      "u_target_guid": "ABC123...",
      "sys_class_name": "cmdb_ci_db_ora_instance",
      "category": "Database",
      "subcategory": "Oracle",
      "host_name": "dbserver01.example.com",
      "ip_address": "10.1.2.30",
      "version": "19.18.0.0.0",
      "database_name": "PRODDB",
      "instance_name": "PRODDB01",
      "oracle_home": "/u01/app/oracle/product/19c/dbhome_1",
      "tcp_port": "1521",
      "service_name": "proddb.example.com,proddb_ro.example.com",
      "operational_status": "1",
      "u_availability_status": "Up",
      "discovery_source": "OEM:OEM-PROD-01",
      "last_discovered": "2026-04-27T14:30:15.789012+00:00",
      "u_target_type": "oracle_database",
      "u_is_rac": false,
      "u_is_pdb": false,
      "attributes": {
        "...all raw OEM properties..."
      }
    }
  ]
}


## Security Considerations
For production use, replace the plaintext passwords in config.json with one of these approaches:

Environment variables — modify the script to read os.environ.get('OEM_PROD_PASSWORD')
Oracle Wallet — configure EMCLI to use wallet-based authentication
HashiCorp Vault or similar — fetch credentials at runtime
Encrypted config — use a library like cryptography to decrypt the config file