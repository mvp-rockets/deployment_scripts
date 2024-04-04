
run `setup.sh` to install all dependencies
run `vagrant up` to get the instance up
`ssh -i golden-key ubuntu@192.168.56.20` to connect to api
`ssh -i golden-key ubuntu@192.168.56.30` to connect to web

Within the guest machine you can reach out to the host with either of the following IP address
- 192.168.56.1
- 10.0.2.2

For e.g.
`psql -h 10.0.2.2 -U root`
`redis-cli -h 10.0.2.2`
