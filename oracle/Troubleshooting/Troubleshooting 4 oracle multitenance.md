- Grid Won't Start
```bash
crsctl check crs
ls -la $ORACLE_HOME/log/
sudo /u01/app/grid/bin/crsctl stop crs
sudo /u01/app/grid/bin/crsctl start crs
```

- ASM Not Found
```bash
ls -la $ORACLE_HOME/asm/
srvctl start asm
```

- Permission Denied
```bash
ls -ld /u01/app/grid
sudo chown -R oracle:oinstall /u01/app/grid
sudo chmod -R 755 /u01/app/grid
```

- Database Won't Start
```bash
sqlplus / as sysdba
SQL> startup
tail -100 $ORACLE_BASE/diag/rdbms/PROD/PROD/trace/alert_orclcdb.log
```

- Listener Issues
```bash
lsnrctl status
lsnrctl stop
lsnrctl start
cat $ORACLE_HOME/network/admin/listener.ora
```

- Can't Connect
```bash
tnsping orclcdb
cat $ORACLE_HOME/network/admin/tnsnames.ora
```

- Reference Directories
```bash
/u01/app/grid                          - Grid Infrastructure Home
/u01/app/oracle                        - Oracle Base
/u01/app/oracle/product/19.0.0/dbhome_1 - Database Home
/u01/app/oracle/oradata               - Database Datafiles
/u01/app/oraInventory                 - Oracle Inventory
```