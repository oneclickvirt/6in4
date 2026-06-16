Historical compatibility entries:

```bash
curl -L https://raw.githubusercontent.com/oneclickvirt/6in4/main/back/test.sh -o test.sh
chmod +x test.sh
bash test.sh <client_ipv4> [mode_type] [subnet_size]
```

`back/6in4.sh` and `back/test.sh` now delegate to the maintained root `6in4.sh` implementation.
