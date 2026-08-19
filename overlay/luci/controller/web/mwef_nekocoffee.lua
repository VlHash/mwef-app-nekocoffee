module("luci.controller.web.mwef_nekocoffee", package.seeall)

function index()
    local page = entry(
        {"web", "xqext", "nekocoffee"},
        template("web/xqext/nekocoffee"),
        _("NekoCoffee"),
        30
    )
    page.leaf = true

    local api = entry(
        {"web", "xqext", "nekocoffee_api"},
        call("dispatch_api"),
        nil
    )
    api.leaf = true
end
function dispatch_api()
    require("luci.controller.api.mwef_nekocoffee").dispatch()
end
