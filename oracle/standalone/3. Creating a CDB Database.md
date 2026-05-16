### 1. Xóa database non-cdb cũ:

```bash
su oracle
cd ${ORACLE_HOME}/bin
dbca -silent -deleteDatabase -sourceDB ${ORACLE_SID} -sysDBAUserName sys -sysDBAPassword Amin@123
```
