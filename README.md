# kickstart


```
docker compose build
docker compose run -it debian-machine bash
```

Vytvořit DEB
```
./create-debs.sh


# kontrola
dpkg-deb -c ./snakeoil-datalogger_1.0_all.deb
```