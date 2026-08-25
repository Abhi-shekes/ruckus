// System tray, implemented directly against the StatusNotifierItem spec.
//
// The usual route is libayatana-appindicator, which would add a build
// dependency the user may not have. StatusNotifierItem is just two D-Bus
// interfaces, and GLib already ships everything needed to export them, so this
// talks to the desktop's tray host directly and needs nothing beyond GTK.
//
//   org.kde.StatusNotifierItem   the icon, its tooltip, and Activate
//   com.canonical.dbusmenu       the menu that drops down from it
//
// Menu items are pushed in from Dart as a flat list; clicks come back through
// one callback carrying the item id.

#include "sb_tray.h"

#include <gio/gio.h>
#include <string.h>

#define MAX_ITEMS 32

typedef struct {
  int   id;
  char* label;
  int   kind;      // SB_MENU_NORMAL | SB_MENU_CHECK | SB_MENU_SEPARATOR
  int   checked;
  int   enabled;
} TrayItem;

static GDBusConnection* g_bus;
static guint            g_item_reg;
static guint            g_menu_reg;
static guint            g_owned_name;
static sb_tray_callback g_cb;

static TrayItem g_items[MAX_ITEMS];
static int      g_item_count;
static char     g_icon_name[128] = "audio-x-generic";
static char     g_tooltip[256]   = "Ruckus";
static char     g_bus_name[128];
static guint    g_menu_revision = 1;

// ---------------------------------------------------------------- interfaces

static const char kItemXml[] =
    "<node><interface name='org.kde.StatusNotifierItem'>"
    "  <property name='Category' type='s' access='read'/>"
    "  <property name='Id' type='s' access='read'/>"
    "  <property name='Title' type='s' access='read'/>"
    "  <property name='Status' type='s' access='read'/>"
    "  <property name='IconName' type='s' access='read'/>"
    "  <property name='ToolTip' type='(sa(iiay)ss)' access='read'/>"
    "  <property name='Menu' type='o' access='read'/>"
    "  <property name='ItemIsMenu' type='b' access='read'/>"
    "  <method name='Activate'><arg name='x' type='i' direction='in'/>"
    "    <arg name='y' type='i' direction='in'/></method>"
    "  <method name='SecondaryActivate'><arg name='x' type='i' direction='in'/>"
    "    <arg name='y' type='i' direction='in'/></method>"
    "  <method name='Scroll'><arg name='delta' type='i' direction='in'/>"
    "    <arg name='dir' type='s' direction='in'/></method>"
    "  <signal name='NewIcon'/><signal name='NewToolTip'/>"
    "  <signal name='NewStatus'><arg name='status' type='s'/></signal>"
    "</interface></node>";

static const char kMenuXml[] =
    "<node><interface name='com.canonical.dbusmenu'>"
    "  <property name='Version' type='u' access='read'/>"
    "  <property name='Status' type='s' access='read'/>"
    "  <property name='TextDirection' type='s' access='read'/>"
    "  <property name='IconThemePath' type='as' access='read'/>"
    "  <method name='GetLayout'>"
    "    <arg name='parentId' type='i' direction='in'/>"
    "    <arg name='recursionDepth' type='i' direction='in'/>"
    "    <arg name='propertyNames' type='as' direction='in'/>"
    "    <arg name='revision' type='u' direction='out'/>"
    "    <arg name='layout' type='(ia{sv}av)' direction='out'/>"
    "  </method>"
    "  <method name='GetGroupProperties'>"
    "    <arg name='ids' type='ai' direction='in'/>"
    "    <arg name='propertyNames' type='as' direction='in'/>"
    "    <arg name='properties' type='a(ia{sv})' direction='out'/>"
    "  </method>"
    "  <method name='GetProperty'>"
    "    <arg name='id' type='i' direction='in'/>"
    "    <arg name='name' type='s' direction='in'/>"
    "    <arg name='value' type='v' direction='out'/>"
    "  </method>"
    "  <method name='Event'>"
    "    <arg name='id' type='i' direction='in'/>"
    "    <arg name='eventId' type='s' direction='in'/>"
    "    <arg name='data' type='v' direction='in'/>"
    "    <arg name='timestamp' type='u' direction='in'/>"
    "  </method>"
    "  <method name='AboutToShow'>"
    "    <arg name='id' type='i' direction='in'/>"
    "    <arg name='needUpdate' type='b' direction='out'/>"
    "  </method>"
    "  <signal name='LayoutUpdated'>"
    "    <arg name='revision' type='u'/><arg name='parent' type='i'/>"
    "  </signal>"
    "  <signal name='ItemsPropertiesUpdated'>"
    "    <arg name='updated' type='a(ia{sv})'/><arg name='removed' type='a(ias)'/>"
    "  </signal>"
    "</interface></node>";

static GDBusNodeInfo* g_item_info;
static GDBusNodeInfo* g_menu_info;

// ---------------------------------------------------------------- menu model

static void item_props(const TrayItem* it, GVariantBuilder* b) {
  if (it->kind == SB_MENU_SEPARATOR) {
    g_variant_builder_add(b, "{sv}", "type", g_variant_new_string("separator"));
    return;
  }
  g_variant_builder_add(b, "{sv}", "label", g_variant_new_string(it->label));
  g_variant_builder_add(b, "{sv}", "enabled",
                        g_variant_new_boolean(it->enabled != 0));
  g_variant_builder_add(b, "{sv}", "visible", g_variant_new_boolean(TRUE));
  if (it->kind == SB_MENU_CHECK) {
    g_variant_builder_add(b, "{sv}", "toggle-type",
                          g_variant_new_string("checkmark"));
    g_variant_builder_add(b, "{sv}", "toggle-state",
                          g_variant_new_int32(it->checked ? 1 : 0));
  }
}

static GVariant* build_layout(void) {
  GVariantBuilder children;
  g_variant_builder_init(&children, G_VARIANT_TYPE("av"));

  for (int i = 0; i < g_item_count; i++) {
    GVariantBuilder props;
    g_variant_builder_init(&props, G_VARIANT_TYPE("a{sv}"));
    item_props(&g_items[i], &props);

    GVariantBuilder empty;
    g_variant_builder_init(&empty, G_VARIANT_TYPE("av"));

    g_variant_builder_add(
        &children, "v",
        g_variant_new("(ia{sv}av)", g_items[i].id, &props, &empty));
  }

  GVariantBuilder root_props;
  g_variant_builder_init(&root_props, G_VARIANT_TYPE("a{sv}"));
  g_variant_builder_add(&root_props, "{sv}", "children-display",
                        g_variant_new_string("submenu"));

  return g_variant_new("(ia{sv}av)", 0, &root_props, &children);
}

static void emit_layout_updated(void) {
  if (!g_bus) return;
  g_menu_revision++;
  g_dbus_connection_emit_signal(
      g_bus, NULL, SB_TRAY_MENU_PATH, "com.canonical.dbusmenu",
      "LayoutUpdated", g_variant_new("(ui)", g_menu_revision, 0), NULL);
}

// ---------------------------------------------------------------- item iface

static void item_method(GDBusConnection* conn, const gchar* sender,
                        const gchar* path, const gchar* iface,
                        const gchar* method, GVariant* params,
                        GDBusMethodInvocation* inv, gpointer user_data) {
  (void)conn; (void)sender; (void)path; (void)iface; (void)params; (void)user_data;

  if (g_strcmp0(method, "Activate") == 0 && g_cb) {
    g_cb(SB_TRAY_ACTIVATE);
  } else if (g_strcmp0(method, "SecondaryActivate") == 0 && g_cb) {
    g_cb(SB_TRAY_ACTIVATE);
  }
  g_dbus_method_invocation_return_value(inv, NULL);
}

static GVariant* item_get_prop(GDBusConnection* conn, const gchar* sender,
                               const gchar* path, const gchar* iface,
                               const gchar* prop, GError** error,
                               gpointer user_data) {
  (void)conn; (void)sender; (void)path; (void)iface; (void)error; (void)user_data;

  if (g_strcmp0(prop, "Category") == 0)
    return g_variant_new_string("ApplicationStatus");
  if (g_strcmp0(prop, "Id") == 0) return g_variant_new_string("ruckus");
  if (g_strcmp0(prop, "Title") == 0) return g_variant_new_string("Ruckus");
  if (g_strcmp0(prop, "Status") == 0) return g_variant_new_string("Active");
  if (g_strcmp0(prop, "IconName") == 0)
    return g_variant_new_string(g_icon_name);
  if (g_strcmp0(prop, "Menu") == 0)
    return g_variant_new_object_path(SB_TRAY_MENU_PATH);
  if (g_strcmp0(prop, "ItemIsMenu") == 0) return g_variant_new_boolean(FALSE);
  if (g_strcmp0(prop, "ToolTip") == 0) {
    GVariantBuilder icon;
    g_variant_builder_init(&icon, G_VARIANT_TYPE("a(iiay)"));
    return g_variant_new("(sa(iiay)ss)", g_icon_name, &icon, "Ruckus",
                         g_tooltip);
  }
  return NULL;
}

static const GDBusInterfaceVTable kItemVTable = {item_method, item_get_prop,
                                                 NULL, {0}};

// ---------------------------------------------------------------- menu iface

static void menu_method(GDBusConnection* conn, const gchar* sender,
                        const gchar* path, const gchar* iface,
                        const gchar* method, GVariant* params,
                        GDBusMethodInvocation* inv, gpointer user_data) {
  (void)conn; (void)sender; (void)path; (void)iface; (void)user_data;

  if (g_strcmp0(method, "GetLayout") == 0) {
    g_dbus_method_invocation_return_value(
        inv, g_variant_new("(u@(ia{sv}av))", g_menu_revision, build_layout()));
    return;
  }

  if (g_strcmp0(method, "GetGroupProperties") == 0) {
    GVariantBuilder out;
    g_variant_builder_init(&out, G_VARIANT_TYPE("a(ia{sv})"));
    for (int i = 0; i < g_item_count; i++) {
      GVariantBuilder props;
      g_variant_builder_init(&props, G_VARIANT_TYPE("a{sv}"));
      item_props(&g_items[i], &props);
      g_variant_builder_add(&out, "(ia{sv})", g_items[i].id, &props);
    }
    g_dbus_method_invocation_return_value(inv, g_variant_new("(a(ia{sv}))", &out));
    return;
  }

  if (g_strcmp0(method, "GetProperty") == 0) {
    gint32 id; const gchar* name;
    g_variant_get(params, "(i&s)", &id, &name);
    for (int i = 0; i < g_item_count; i++) {
      if (g_items[i].id != id) continue;
      if (g_strcmp0(name, "label") == 0) {
        g_dbus_method_invocation_return_value(
            inv, g_variant_new("(v)", g_variant_new_string(g_items[i].label)));
        return;
      }
      if (g_strcmp0(name, "toggle-state") == 0) {
        g_dbus_method_invocation_return_value(
            inv, g_variant_new("(v)",
                               g_variant_new_int32(g_items[i].checked ? 1 : 0)));
        return;
      }
    }
    g_dbus_method_invocation_return_value(
        inv, g_variant_new("(v)", g_variant_new_string("")));
    return;
  }

  if (g_strcmp0(method, "Event") == 0) {
    gint32 id; const gchar* event_id;
    g_variant_get(params, "(i&sv u)", &id, &event_id, NULL, NULL);
    if (g_strcmp0(event_id, "clicked") == 0 && g_cb) g_cb(id);
    g_dbus_method_invocation_return_value(inv, NULL);
    return;
  }

  if (g_strcmp0(method, "AboutToShow") == 0) {
    g_dbus_method_invocation_return_value(inv, g_variant_new("(b)", FALSE));
    return;
  }

  g_dbus_method_invocation_return_value(inv, NULL);
}

static GVariant* menu_get_prop(GDBusConnection* conn, const gchar* sender,
                               const gchar* path, const gchar* iface,
                               const gchar* prop, GError** error,
                               gpointer user_data) {
  (void)conn; (void)sender; (void)path; (void)iface; (void)error; (void)user_data;

  if (g_strcmp0(prop, "Version") == 0) return g_variant_new_uint32(3);
  if (g_strcmp0(prop, "Status") == 0) return g_variant_new_string("normal");
  if (g_strcmp0(prop, "TextDirection") == 0) return g_variant_new_string("ltr");
  if (g_strcmp0(prop, "IconThemePath") == 0) {
    GVariantBuilder b;
    g_variant_builder_init(&b, G_VARIANT_TYPE("as"));
    return g_variant_new("as", &b);
  }
  return NULL;
}

static const GDBusInterfaceVTable kMenuVTable = {menu_method, menu_get_prop,
                                                 NULL, {0}};

// ---------------------------------------------------------------- lifecycle

static void register_with_watcher(void) {
  g_dbus_connection_call(
      g_bus, "org.kde.StatusNotifierWatcher", "/StatusNotifierWatcher",
      "org.kde.StatusNotifierWatcher", "RegisterStatusNotifierItem",
      g_variant_new("(s)", g_bus_name), NULL, G_DBUS_CALL_FLAGS_NONE, -1, NULL,
      NULL, NULL);
}

static void on_name_acquired(GDBusConnection* conn, const gchar* name,
                             gpointer user_data) {
  (void)conn; (void)name; (void)user_data;
  register_with_watcher();
}

int32_t sb_tray_start(sb_tray_callback cb) {
  if (g_bus) return SB_TRAY_ERR_ALREADY;

  GError* err = NULL;
  g_bus = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, &err);
  if (!g_bus) {
    if (err) g_error_free(err);
    return SB_TRAY_ERR_NO_BUS;
  }

  g_item_info = g_dbus_node_info_new_for_xml(kItemXml, NULL);
  g_menu_info = g_dbus_node_info_new_for_xml(kMenuXml, NULL);
  if (!g_item_info || !g_menu_info) return SB_TRAY_ERR_NO_BUS;

  g_cb = cb;

  g_item_reg = g_dbus_connection_register_object(
      g_bus, SB_TRAY_ITEM_PATH, g_item_info->interfaces[0], &kItemVTable, NULL,
      NULL, NULL);
  g_menu_reg = g_dbus_connection_register_object(
      g_bus, SB_TRAY_MENU_PATH, g_menu_info->interfaces[0], &kMenuVTable, NULL,
      NULL, NULL);
  if (!g_item_reg || !g_menu_reg) return SB_TRAY_ERR_REGISTER;

  // The spec expects a well-known name of this exact shape.
  g_snprintf(g_bus_name, sizeof g_bus_name,
             "org.kde.StatusNotifierItem-%d-1", getpid());
  g_owned_name = g_bus_own_name_on_connection(
      g_bus, g_bus_name, G_BUS_NAME_OWNER_FLAGS_NONE, on_name_acquired, NULL,
      NULL, NULL);

  return SB_TRAY_OK;
}

void sb_tray_stop(void) {
  if (!g_bus) return;
  if (g_owned_name) g_bus_unown_name(g_owned_name);
  if (g_item_reg) g_dbus_connection_unregister_object(g_bus, g_item_reg);
  if (g_menu_reg) g_dbus_connection_unregister_object(g_bus, g_menu_reg);
  for (int i = 0; i < g_item_count; i++) g_free(g_items[i].label);
  g_item_count = 0;
  g_owned_name = g_item_reg = g_menu_reg = 0;
  g_bus = NULL;
  g_cb = NULL;
}

void sb_tray_clear_menu(void) {
  for (int i = 0; i < g_item_count; i++) g_free(g_items[i].label);
  g_item_count = 0;
}

void sb_tray_add_item(int32_t id, const char* label, int32_t kind,
                      int32_t checked, int32_t enabled) {
  if (g_item_count >= MAX_ITEMS) return;
  TrayItem* it = &g_items[g_item_count++];
  it->id = id;
  it->label = g_strdup(label ? label : "");
  it->kind = kind;
  it->checked = checked;
  it->enabled = enabled;
}

void sb_tray_commit_menu(void) { emit_layout_updated(); }

void sb_tray_set_tooltip(const char* text) {
  g_strlcpy(g_tooltip, text ? text : "Ruckus", sizeof g_tooltip);
  if (g_bus) {
    g_dbus_connection_emit_signal(g_bus, NULL, SB_TRAY_ITEM_PATH,
                                  "org.kde.StatusNotifierItem", "NewToolTip",
                                  NULL, NULL);
  }
}

void sb_tray_set_icon(const char* icon_name) {
  g_strlcpy(g_icon_name, icon_name ? icon_name : "audio-x-generic",
            sizeof g_icon_name);
  if (g_bus) {
    g_dbus_connection_emit_signal(g_bus, NULL, SB_TRAY_ITEM_PATH,
                                  "org.kde.StatusNotifierItem", "NewIcon", NULL,
                                  NULL);
  }
}
