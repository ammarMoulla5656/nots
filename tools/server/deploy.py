"""Puts the statistics service on the server, under nots/api/ only.

    python deploy.py            # the PHP files and the data folder's .htaccess
    python deploy.py --geo F    # also the country table (geo.sqlite, built
                                # from the DB-IP Lite CSV; see README.md)

It goes through the publisher's guarded FTP class, which refuses any path
outside nots/, with the account saved by the publisher (never in the repo).
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "publisher"))
from nots_publisher.server import Account, Server  # noqa: E402

FILES = ["lib.php", "collect.php", "admin.php", "data/.htaccess"]

with Server(Account.load()) as s:
    for f in FILES:
        s.upload_file(os.path.join(HERE, "api", *f.split("/")), "api/" + f)
        print("put api/" + f)
    if "--geo" in sys.argv:
        geo = sys.argv[sys.argv.index("--geo") + 1]
        s.upload_file(geo, "api/data/geo.sqlite")
        print("put api/data/geo.sqlite")
