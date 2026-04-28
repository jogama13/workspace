#!/usr/bin/env python3
"""
OEM Instance Discovery Script
Queries Oracle Enterprise Manager servers via EMCLI and exports
database instance information to JSON for ServiceNow CMDB.
"""
import subprocess
import json
import logging
import re
from datetime import datetime, timezone
from pathlib import Path
from dataclasses import dataclass, field, asdict
from typing import Optional
from concurrent.futures import ThreadPoolExecutor, as_completed
# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)
@dataclass
class OEMServer:
    """OEM Server connection configuration."""
    name: str
    url: str
    username: str
    password: str
    trust_all_certs: bool = True
@dataclass
class OracleInstance:
    """Oracle database instance information for CMDB."""
    # Identity
    target_name: str
    target_type: str
    target_guid: str = ""
    
    # Host information
    host_name: str = ""
    host_ip: str = ""
    
    # Database details
    oracle_home: str = ""
    version: str = ""
    database_name: str = ""
    instance_name: str = ""
    
    # Configuration
    listener_port: str = ""
    service_names: list = field(default_factory=list)
    
    # Status
    status: str = ""
    availability_status: str = ""
    
    # Metadata
    oem_server: str = ""
    discovered_at: str = ""
    
    # Additional properties (captured dynamically)
    properties: dict = field(default_factory=dict)
class EMCLIWrapper:
    """Wrapper for EMCLI command execution."""
    
    def __init__(self, emcli_path: str = "emcli"):
        self.emcli_path = emcli_path
    
    def execute(self, server: OEMServer, command: str, args: list = None) -> tuple[bool, str]:
        """
        Execute an EMCLI command against an OEM server.
        Returns (success, output).
        """
        args = args or []
        
        # Build the full command
        cmd = [
            self.emcli_path,
            command,
            f"-url={server.url}",
            f"-username={server.username}",
            f"-password={server.password}",
        ]
        
        if server.trust_all_certs:
            cmd.append("-trust_all_certs")
        
        cmd.extend(args)
        
        try:
            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=300  # 5 minute timeout
            )
            
            if result.returncode != 0:
                logger.error(f"EMCLI error on {server.name}: {result.stderr}")
                return False, result.stderr
            
            return True, result.stdout
            
        except subprocess.TimeoutExpired:
            logger.error(f"EMCLI timeout on {server.name}")
            return False, "Command timed out"
        except FileNotFoundError:
            logger.error(f"EMCLI not found at path: {self.emcli_path}")
            return False, "EMCLI executable not found"
        except Exception as e:
            logger.error(f"EMCLI execution error: {e}")
            return False, str(e)
    
    def login(self, server: OEMServer) -> bool:
        """Establish EMCLI session with OEM server."""
        success, output = self.execute(server, "login")
        if success:
            logger.info(f"Successfully logged into {server.name}")
        return success
    
    def logout(self, server: OEMServer) -> bool:
        """Close EMCLI session."""
        success, _ = self.execute(server, "logout")
        return success
class OEMDiscovery:
    """Discovers Oracle instances from OEM servers."""
    
    # Target types we're interested in
    DATABASE_TARGET_TYPES = [
        "oracle_database",
        "rac_database", 
        "oracle_pdb",
    ]
    
    def __init__(self, emcli: EMCLIWrapper):
        self.emcli = emcli
    
    def get_targets(self, server: OEMServer) -> list[dict]:
        """Retrieve all database targets from OEM."""
        targets = []
        
        for target_type in self.DATABASE_TARGET_TYPES:
            success, output = self.emcli.execute(
                server,
                "get_targets",
                [
                    f"-targets={target_type}",
                    "-format=name:csv",
                    "-noheader"
                ]
            )
            
            if success and output.strip():
                parsed = self._parse_csv_output(output)
                for row in parsed:
                    if len(row) >= 2:
                        targets.append({
                            "target_name": row[0],
                            "target_type": target_type,
                            "status": row[1] if len(row) > 1 else "Unknown"
                        })
        
        logger.info(f"Found {len(targets)} database targets on {server.name}")
        return targets
    
    def get_target_properties(self, server: OEMServer, target_name: str, target_type: str) -> dict:
        """Retrieve detailed properties for a specific target."""
        success, output = self.emcli.execute(
            server,
            "get_target_properties",
            [
                f"-target_name={target_name}",
                f"-target_type={target_type}",
                "-format=name:csv"
            ]
        )
        
        properties = {}
        if success:
            # Parse property output (typically "property_name,property_value" format)
            for line in output.strip().split('\n'):
                if ',' in line and not line.startswith('#'):
                    parts = line.split(',', 1)
                    if len(parts) == 2:
                        prop_name = parts[0].strip()
                        prop_value = parts[1].strip()
                        properties[prop_name] = prop_value
        
        return properties
    
    def get_target_metrics(self, server: OEMServer, target_name: str, target_type: str) -> dict:
        """Retrieve key metrics for a target."""
        metrics = {}
        
        # Get availability status
        success, output = self.emcli.execute(
            server,
            "get_availability_status",
            [
                f"-target_name={target_name}",
                f"-target_type={target_type}"
            ]
        )
        
        if success:
            metrics["availability_status"] = output.strip()
        
        return metrics
    
    def discover_instance(self, server: OEMServer, target: dict) -> Optional[OracleInstance]:
        """Build complete instance information from OEM data."""
        target_name = target["target_name"]
        target_type = target["target_type"]
        
        logger.debug(f"Discovering {target_name} on {server.name}")
        
        # Get detailed properties
        properties = self.get_target_properties(server, target_name, target_type)
        metrics = self.get_target_metrics(server, target_name, target_type)
        
        # Map OEM properties to our instance model
        instance = OracleInstance(
            target_name=target_name,
            target_type=target_type,
            target_guid=properties.get("orcl_gtp_target_guid", ""),
            host_name=properties.get("MachineName", properties.get("host_name", "")),
            host_ip=properties.get("host_ip", ""),
            oracle_home=properties.get("OracleHome", properties.get("orcl_gtp_oracle_home", "")),
            version=properties.get("Version", properties.get("orcl_gtp_version", "")),
            database_name=properties.get("orcl_gtp_db_name", properties.get("DBName", target_name)),
            instance_name=properties.get("orcl_gtp_instance_name", properties.get("SID", "")),
            listener_port=properties.get("Port", properties.get("orcl_gtp_listener_port", "")),
            service_names=self._parse_service_names(properties.get("ServiceName", "")),
            status=target.get("status", "Unknown"),
            availability_status=metrics.get("availability_status", "Unknown"),
            oem_server=server.name,
            discovered_at=datetime.now(timezone.utc).isoformat(),
            properties=properties  # Store all properties for completeness
        )
        
        return instance
    
    def _parse_csv_output(self, output: str) -> list[list[str]]:
        """Parse EMCLI CSV output into rows."""
        rows = []
        for line in output.strip().split('\n'):
            if line and not line.startswith('#'):
                # Handle quoted fields
                row = []
                in_quotes = False
                current_field = []
                for char in line:
                    if char == '"':
                        in_quotes = not in_quotes
                    elif char == ',' and not in_quotes:
                        row.append(''.join(current_field).strip())
                        current_field = []
                    else:
                        current_field.append(char)
                row.append(''.join(current_field).strip())
                rows.append(row)
        return rows
    
    def _parse_service_names(self, service_str: str) -> list[str]:
        """Parse comma or semicolon separated service names."""
        if not service_str:
            return []
        return [s.strip() for s in re.split(r'[,;]', service_str) if s.strip()]
class ServiceNowExporter:
    """Exports instance data to ServiceNow CMDB-compatible JSON."""
    
    def __init__(self, output_dir: str = "."):
        self.output_dir = Path(output_dir)
        self.output_dir.mkdir(parents=True, exist_ok=True)
    
    def export(self, instances: list[OracleInstance], filename: str = None) -> str:
        """
        Export instances to JSON file.
        Returns the path to the created file.
        """
        if filename is None:
            timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
            filename = f"oracle_instances_{timestamp}.json"
        
        filepath = self.output_dir / filename
        
        # Transform to ServiceNow CMDB format
        cmdb_records = [self._to_cmdb_record(inst) for inst in instances]
        
        output = {
            "source": "OEM Discovery",
            "export_timestamp": datetime.now(timezone.utc).isoformat(),
            "record_count": len(cmdb_records),
            "records": cmdb_records
        }
        
        with open(filepath, 'w', encoding='utf-8') as f:
            json.dump(output, f, indent=2, ensure_ascii=False)
        
        logger.info(f"Exported {len(instances)} instances to {filepath}")
        return str(filepath)
    
    def _to_cmdb_record(self, instance: OracleInstance) -> dict:
        """
        Transform OracleInstance to ServiceNow CMDB record format.
        Maps to cmdb_ci_db_ora_instance table structure.
        """
        return {
            # Core identification
            "name": instance.target_name,
            "u_target_guid": instance.target_guid,
            
            # Classification
            "sys_class_name": "cmdb_ci_db_ora_instance",
            "category": "Database",
            "subcategory": "Oracle",
            
            # Host relationship
            "host_name": instance.host_name,
            "ip_address": instance.host_ip,
            
            # Oracle-specific attributes
            "version": instance.version,
            "database_name": instance.database_name,
            "instance_name": instance.instance_name,
            "oracle_home": instance.oracle_home,
            "tcp_port": instance.listener_port,
            "service_name": ",".join(instance.service_names),
            
            # Status
            "operational_status": self._map_status(instance.status),
            "u_availability_status": instance.availability_status,
            
            # Discovery metadata
            "discovery_source": f"OEM:{instance.oem_server}",
            "last_discovered": instance.discovered_at,
            
            # Target type info
            "u_target_type": instance.target_type,
            "u_is_rac": instance.target_type == "rac_database",
            "u_is_pdb": instance.target_type == "oracle_pdb",
            
            # Additional properties (custom fields)
            "attributes": instance.properties
        }
    
    def _map_status(self, oem_status: str) -> str:
        """Map OEM status to ServiceNow operational_status values."""
        status_map = {
            "Up": "1",        # Operational
            "Down": "2",      # Non-Operational  
            "Blackout": "6",  # Retired
            "Unknown": "4",   # Unknown
            "Pending": "5",   # Pending
        }
        return status_map.get(oem_status, "4")
def load_config(config_path: str) -> dict:
    """Load configuration from JSON file."""
    with open(config_path, 'r') as f:
        return json.load(f)
def discover_from_server(
    server: OEMServer, 
    emcli: EMCLIWrapper,
    discovery: OEMDiscovery
) -> list[OracleInstance]:
    """Discover all instances from a single OEM server."""
    instances = []
    
    try:
        # Login to OEM
        if not emcli.login(server):
            logger.error(f"Failed to login to {server.name}")
            return instances
        
        # Get all database targets
        targets = discovery.get_targets(server)
        
        # Discover each target
        for target in targets:
            try:
                instance = discovery.discover_instance(server, target)
                if instance:
                    instances.append(instance)
            except Exception as e:
                logger.error(f"Error discovering {target['target_name']}: {e}")
        
        # Logout
        emcli.logout(server)
        
    except Exception as e:
        logger.error(f"Error processing server {server.name}: {e}")
    
    return instances
def main():
    """Main entry point."""
    import argparse
    
    parser = argparse.ArgumentParser(
        description="Discover Oracle instances from OEM and export to JSON for ServiceNow CMDB"
    )
    parser.add_argument(
        "-c", "--config",
        required=True,
        help="Path to configuration JSON file"
    )
    parser.add_argument(
        "-o", "--output-dir",
        default="./output",
        help="Output directory for JSON files"
    )
    parser.add_argument(
        "--emcli-path",
        default="emcli",
        help="Path to EMCLI executable"
    )
    parser.add_argument(
        "--parallel",
        type=int,
        default=3,
        help="Number of OEM servers to query in parallel"
    )
    parser.add_argument(
        "-v", "--verbose",
        action="store_true",
        help="Enable verbose logging"
    )
    
    args = parser.parse_args()
    
    if args.verbose:
        logging.getLogger().setLevel(logging.DEBUG)
    
    # Load configuration
    config = load_config(args.config)
    
    # Initialize components
    emcli = EMCLIWrapper(args.emcli_path)
    discovery = OEMDiscovery(emcli)
    exporter = ServiceNowExporter(args.output_dir)
    
    # Build server list from config
    servers = [
        OEMServer(
            name=srv["name"],
            url=srv["url"],
            username=srv["username"],
            password=srv["password"],
            trust_all_certs=srv.get("trust_all_certs", True)
        )
        for srv in config.get("oem_servers", [])
    ]
    
    if not servers:
        logger.error("No OEM servers configured")
        return 1
    
    logger.info(f"Starting discovery from {len(servers)} OEM servers")
    
    # Discover instances from all servers (in parallel)
    all_instances = []
    
    with ThreadPoolExecutor(max_workers=args.parallel) as executor:
        futures = {
            executor.submit(discover_from_server, server, emcli, discovery): server
            for server in servers
        }
        
        for future in as_completed(futures):
            server = futures[future]
            try:
                instances = future.result()
                all_instances.extend(instances)
                logger.info(f"Discovered {len(instances)} instances from {server.name}")
            except Exception as e:
                logger.error(f"Discovery failed for {server.name}: {e}")
    
    # Export to JSON
    if all_instances:
        output_file = exporter.export(all_instances)
        logger.info(f"Discovery complete. Total instances: {len(all_instances)}")
        logger.info(f"Output file: {output_file}")
    else:
        logger.warning("No instances discovered")
    
    return 0
if __name__ == "__main__":
    exit(main())