#!/usr/bin/env python3
import base64, importlib.util, pathlib, unittest
spec=importlib.util.spec_from_file_location('config',pathlib.Path(__file__).with_name('client-config.py'))
m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
def jwt(role): return 'header.'+base64.urlsafe_b64encode((' {"role":"'+role+'"}').encode()).decode().rstrip('=')+'.signature'
class ConfigTests(unittest.TestCase):
 def config(self,key='sb_publishable_test',url='https://example.supabase.co'):
  return f'DOORBELL_BACKEND=supabase\nSUPABASE_URL={url}\nSUPABASE_ANON_KEY={key}\n'
 def test_secret_values_never_exported(self):
  output=m.client_config(self.config()+'LIVEKIT_API_SECRET=private\nGOOGLE_CLIENT_SECRET=secret\nDOORBELL_SIGNIN=user:password\n')
  self.assertNotIn('private',output); self.assertNotIn('secret',output); self.assertNotIn('password',output)
 def test_service_role_rejected(self):
  for key in [jwt('service_role'),'sb_secret_test','bad']:
   with self.assertRaises(ValueError): m.client_config(self.config(key))
 def test_anon_allowed(self): self.assertIn(jwt('anon'),m.client_config(self.config(jwt('anon'))))
 def test_no_mock_release(self):
  with self.assertRaises(ValueError): m.client_config('')
 def test_no_local_release(self):
  for url in ['http://example.com','https://localhost','https://127.0.0.1','https://mac.local']:
   with self.assertRaises(ValueError): m.client_config(self.config(url=url))
 def test_debug_mock_explicit(self): self.assertEqual(m.client_config('',local=True),'')
if __name__=='__main__': unittest.main()
