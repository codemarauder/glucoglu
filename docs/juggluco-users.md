# Juggluco users (Libre 1)

A Libre 1 sensor is NFC only. Its data reaches Glucoglu through a Juggluco mirror:
the phone mirrors to a Juggluco receiver on the server, and Glucoglu imports from
the receiver's data folder every 60 s.

Each person with a Libre 1 gets:

- one data folder: `Juggluco/users/NAME/`
- one receiver, with its own port and its own password
- one import into their Glucoglu account

Libre 2 and Libre 3 users do not need this. Their Juggluco uploader sends to
`/api/v1/entries` directly, with the ingest token from Settings.

## Rules

- NAME: lower case letters, digits, `_` and `-` only.
- Ports: 9001 to 9010, one port for each person. Do not use a port two times.
- Passwords: a new random password for each person. Do not reuse a password.
- Always give `-d users/NAME` to `./juggluco`. Without `-d`, Juggluco uses the
  folder in `.jugglucorc`, which can be the folder of another person.
- Run all commands as the owner of the Juggluco folder (`GLUCOGLU_UID` in `.env`),
  in the folder `Juggluco/` next to `docker-compose.yml`.

## Add a person

Before you start: the person must have a Glucoglu account. Make an invite code,
send it to them, and let them register and log in one time:

```sh
docker exec -u glucoglu glucoglu perl script/glucoglu-admin invite
```

### On the server

1. Find a free port. This shows the ports in use:

```sh
   cd Juggluco
   for d in users/*/; do printf '%s ' "$d"; ./juggluco -d "$d" -l 2>/dev/null | grep 'Mirror port'; done
```

2. Stop the receivers:

```sh
   docker compose stop juggluco
```

3. Make the data folder and set the port and the unit:

```sh
   mkdir users/NAME
   ./juggluco -d users/NAME -p PORT
   ./juggluco -d users/NAME -G
```

4. Make a password:

```sh
   tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16; echo
```

5. Make the receiving connection:

```sh
   ./juggluco -d users/NAME -r -i -P -L NAME -w PASSWORD
```

   - `-r`: receive from the phone.
   - `-i`: accept any IP address (the address of a phone changes).
   - `-P`: passive: wait for the phone, never connect to it.
   - `-L NAME`: the label. The phone must use the same label.
   - `-w PASSWORD`: encrypts the mirror. The phone must use the same password.

6. Check the configuration:

```sh
   ./juggluco -d users/NAME -l 2>/dev/null
```

   The output must show `Mirror port PORT`, `unit: mg/dL`, and one connection
   `NAME` with `receiver passiveonly`.

7. Write the account of the person:

```sh
   printf 'EMAIL=their@email\n' > users/NAME/user.conf
```

8. Start the containers again. They read `users/` at each start:

```sh
   cd ..
   docker compose restart
   docker logs glucoglu 2>&1 | grep entrypoint
   docker logs juggluco 2>&1 | grep entrypoint
```

   The number of Juggluco users must include the new person.

9. Send these four values to the person in a private message:
   server address, PORT, label NAME, PASSWORD.

### On the phone

1. Open Juggluco. Open the left menu, then **Mirror**.
2. Add a connection (or open the existing one).
3. Set these values:
   - **IP**: the server address (for example `glucoglu.org`)
   - **Port**: PORT
   - **Label**: NAME
   - **Password**: PASSWORD
4. Select **Send scans**. Select **Send stream** too, if the phone also has Bluetooth
   data. Do not select **Receive from**.
5. Save the connection.
6. Scan the sensor.

To send the old data too, use the resend option of the connection.

### Check

After a scan, wait 2 minutes. Then:

```sh
docker logs --tail 5 glucoglu
```

The log must show a line `imported N history readings for their@email` with N
greater than 0 (after a resend, many readings). The person's dashboard shows the
new reading.

If nothing arrives, turn on the receiver log: set `JUGGLUCO_DEBUG=1` in `.env`,
run `docker compose up -d`, scan again, and read `docker logs juggluco`.
A line with `ascon_aead128a_decrypt_final valid` means that the password is
correct. Set `JUGGLUCO_DEBUG=0` again after the test.

## Change the password (or the label)

1. On the server:

```sh
   docker compose stop juggluco
   cd Juggluco
   ./juggluco -d users/NAME -l 2>/dev/null        # the connection has number 1
   ./juggluco -d users/NAME -R 1                   # remove connection 1
   ./juggluco -d users/NAME -r -i -P -L NAME -w NEWPASSWORD
   ./juggluco -d users/NAME -l 2>/dev/null        # check: one connection, new password
   cd ..
   docker compose start juggluco
```

2. On the phone: open the mirror connection, set the new password, and save.

The data in the folder stays. Only the connection changes.

## Change the server address or the port

- **New server address:** change only the **IP** on the phone.
- **New port:** do steps 2, 3 (only the `-p` command), and 8 of "Add a person"
  on the server. Then change the **Port** on the phone.

## Remove a person

```sh
docker compose stop juggluco
rm -rf Juggluco/users/NAME
docker compose up -d
```

This removes only the Juggluco data on the server. The readings stay in Glucoglu.
To delete the account and its readings too:

```sh
docker exec -u glucoglu glucoglu perl script/glucoglu-admin delete their@email
```

## Limits

- 10 receivers: ports 9001 to 9010. For more, widen the port range in
  `docker-compose.yml`. Each published port runs one docker-proxy process.
- Each receiver uses about 5 MB of memory.
- The Juggluco version on the phone and on the server must be compatible. When a
  person updates Juggluco on their phone and the mirror stops, update the server
  binary too.
