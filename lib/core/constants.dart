// P2P is tried first on every platform, falling back to routed when it can't
// be established -- still user-toggleable in Settings.
const bool defaultWebRtcEnabled = true;

class DeskconnConfig {
  static const String quicAddr = "api.deskconn.com:8081";
  static const String wampWsUrl = "wss://api.deskconn.com/ws";
  static const String realm = "io.xconn.deskconn";

  static const String mobileAppAuthRole = "xconnio:deskconn:app:mobile";
  static const String mobileAppAuthID = "deskconn-mobile-app";
  static const String servicePrivateKey = "e61df0b4337879d70119b7294ba48d12dcf9b2d9dce85da4f40641b1cc4e3b65";

  static const Duration callTimeout = Duration(seconds: 10);
}

class DeskconnProcedures {
  static const String accountCreate = 'io.xconn.deskconn.account.create';
  static const String accountDelete = 'io.xconn.deskconn.account.delete';
  static const String accountGet = 'io.xconn.deskconn.account.get';
  static const String accountLogin = 'io.xconn.deskconn.account.login';
  static const String accountLoginVerify = 'io.xconn.deskconn.account.login.verify';
  static const String accountPasswordForget = 'io.xconn.deskconn.account.password.forget';
  static const String accountPasswordReset = 'io.xconn.deskconn.account.password.reset';
  static const String accountUpdate = 'io.xconn.deskconn.account.update';
  static const String accountVerify = 'io.xconn.deskconn.account.verify';
  static const String accountOtpResend = 'io.xconn.deskconn.account.otp.resend';
  static const String accountPrincipalDelete = 'io.xconn.deskconn.account.principal.delete';
  static const String accountPrincipalRotate = 'io.xconn.deskconn.account.principal.rotate';

  static const String desktopList = 'io.xconn.deskconn.desktop.list';
  static const String deviceCreate = 'io.xconn.deskconn.device.create';
  static const String deviceDelete = 'io.xconn.deskconn.device.delete';

  static const String deskconndAppIcon = 'io.xconn.deskconn.app.icon';
  static const String deskconndAppList = 'io.xconn.deskconn.app.list';
  static const String deskconndAudioIsMuted = 'io.xconn.remotecontrol.audio.ismuted';
  static const String deskconndAudioToggleMute = 'io.xconn.remotecontrol.audio.togglemute';
  static const String deskconndMachineInfo = 'io.xconn.deskconn.machine.info';
  static const String deskconndFileBrowse = 'io.xconn.deskconn.file.browse';
  static const String deskconndFileCopy = 'io.xconn.deskconn.file.copy';
  static const String deskconndFileDelete = 'io.xconn.deskconn.file.delete';
  static const String deskconndFileRename = 'io.xconn.deskconn.file.rename';
  static const String deskconndIndexQuery = 'io.xconn.deskconn.index.query';
  static const String deskconndKeyExchange = 'io.xconn.deskconn.key.exchange';
  static const String deskconndPing = 'io.xconn.deskconn.ping';
  static const String deskconndRemoteControlKeyExchange = 'io.xconn.deskconn.remotecontrol.key.exchange';
  static const String deskconndMprisNext = 'io.xconn.remotecontrol.mpris.next';
  static const String deskconndMprisPlayers = 'io.xconn.remotecontrol.mpris.players';
  static const String deskconndMprisPlayPause = 'io.xconn.remotecontrol.mpris.playpause';
  static const String deskconndMprisPrevious = 'io.xconn.remotecontrol.mpris.previous';
  static const String deskconndProcessList = 'io.xconn.deskconn.process.list';
  static const String deskconndProcessSignal = 'io.xconn.deskconn.process.signal';
  static const String deskconndScreenBrightnessGet = 'io.xconn.remotecontrol.screen.brightness.get';
  static const String deskconndScreenBrightnessSet = 'io.xconn.remotecontrol.screen.brightness.set';
  static const String deskconndScreenLock = 'io.xconn.remotecontrol.screen.lock';
  static const String deskconndScreenshot = 'io.xconn.remotecontrol.screenshot';
  static const String deskconndShell = 'io.xconn.deskconn.shell';
  static const String deskconndWallpaperChecksum = 'io.xconn.deskconn.wallpaper.checksum';
  static const String deskconndWallpaperGet = 'io.xconn.deskconn.wallpaper.get';

  static const String webrtcOffer = 'io.xconn.webrtc.offer';
  static const String webrtcAnswererOnCandidate = 'io.xconn.webrtc.answerer.on_candidate';
  static const String webrtcOffererOnCandidate = 'io.xconn.webrtc.offerer.on_candidate';
}
