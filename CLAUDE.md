- never modify infrastructure on your own
- keep all *.md files updated especially diagrams
- never allow any form of committed secret to exist outside of the secrets/ submodule
- never allow any form of committed secret to not be encrypted
- ansible-vault values should not be quoted
- when we delete an app from the flux layer that used fast storage we should delete its backups in s3 (garage on NAS)

