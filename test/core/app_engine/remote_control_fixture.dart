/// The Remote Control example as deskconn-userd's manifest.get returns it.
Map<String, dynamic> remoteControlManifest() => {
  'schema_version': '1',
  'app': {
    'id': 'remote-control',
    'name': 'Remote Control',
    'description': 'Lock your computer and control audio',
    'icon': 'https://example.com/icons/remote-control.png',
  },
  'api': {'key_exchange': 'io.xconn.deskconn.deskconnd.remotecontrol.key.exchange'},
  'permissions': [
    'io.xconn.deskconn.deskconnd.screen.lock',
    'io.xconn.deskconn.deskconnd.audio.ismuted',
    'io.xconn.deskconn.deskconnd.audio.togglemute',
  ],
  'entry_screen': 'home',
  'screens': {
    'home': {
      'id': 'home',
      'title': 'Remote Control',
      'layout': {
        'type': 'grid',
        'columns': 2,
        'children': [
          {
            'id': 'lock',
            'visible': {'bind': 'context.capabilities.screen'},
            'block': {
              'component': {
                'type': 'button',
                'label': 'Lock screen',
                'icon': 'https://example.com/icons/lock.png',
                'on_activate': {'call': 'io.xconn.deskconn.deskconnd.screen.lock'},
              },
            },
          },
          {
            'id': 'mute',
            'visible': {'bind': 'context.capabilities.audio'},
            'block': {
              'state': {'muted': false},
              'subscriptions': [
                {
                  'topic': 'io.xconn.deskconn.deskconnd.audio.on_change',
                  'on_event': {
                    'set': {
                      'muted': {'bind': 'event.muted'},
                    },
                  },
                },
              ],
              'on_mount': {
                'call': 'io.xconn.deskconn.deskconnd.audio.ismuted',
                'on_result': {
                  'set': {
                    'muted': {'bind': 'result'},
                  },
                },
              },
              'component': {
                'type': 'button',
                'label': {
                  'when': {'bind': 'state.muted'},
                  'then': 'Unmute',
                  'else': 'Mute',
                },
                'icon': {
                  'when': {'bind': 'state.muted'},
                  'then': 'https://example.com/icons/volume-off.png',
                  'else': 'https://example.com/icons/volume-on.png',
                },
                'on_activate': {
                  'call': 'io.xconn.deskconn.deskconnd.audio.togglemute',
                  'on_result': {
                    'set': {
                      'muted': {'bind': 'result'},
                    },
                  },
                },
              },
            },
          },
        ],
      },
    },
  },
};
