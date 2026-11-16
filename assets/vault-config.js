/* The Vaulted Shelf — public config shared by every page.
   Public by design: the Supabase publishable key only. Never put the
   service-role key, order numbers, claim codes, or puzzle answers here. */
(function () {
  var base = {
    siteUrl: "https://vaultedshelf.com/",
    storePath: "store/",            // vaultedshelf.com/store → eBay shop (redirect lives in /store/)
    supabase: {
      url: "https://yzfhecjvuorvvsrfoktt.supabase.co",
      anonKey: "sb_publishable_mJYL7HRJypKvKykN2ZNtHw_Wi7mmOW9"
    }
  };
  var cur = window.VAULT_CONFIG || {};
  for (var k in base) if (!(k in cur)) cur[k] = base[k];
  window.VAULT_CONFIG = cur;
})();
