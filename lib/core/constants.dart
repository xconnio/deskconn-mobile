const bool defaultWebRtcEnabled = true;

class DeskconnConfig {
  static const String quicAddr = "api.deskconn.com:8081";
  static const String wampWsUrl = "wss://api.deskconn.com/ws";
  static const String realm = "io.xconn.deskconn";
  static const String standaloneRealm = "io.xconn.deskconn.standalone";

  static const String mobileAppAuthRole = "xconnio:deskconn:app:mobile";
  static const String mobileAppAuthID = "deskconn-mobile-app";
  static const String servicePrivateKey = "e61df0b4337879d70119b7294ba48d12dcf9b2d9dce85da4f40641b1cc4e3b65";

  static const Duration callTimeout = Duration(seconds: 10);
}

class DeskconnProcedures {
  static const String accountCreate = 'com.deskconn.account.create';
  static const String accountDelete = 'com.deskconn.account.delete';
  static const String accountGet = 'com.deskconn.account.get';
  static const String accountLogin = 'com.deskconn.account.login';
  static const String accountLoginVerify = 'com.deskconn.account.login.verify';
  static const String accountPasswordForget = 'com.deskconn.account.password.forget';
  static const String accountPasswordReset = 'com.deskconn.account.password.reset';
  static const String accountUpdate = 'com.deskconn.account.update';
  static const String accountVerify = 'com.deskconn.account.verify';
  static const String accountOtpResend = 'com.deskconn.account.otp.resend';
  static const String accountPrincipalDelete = 'com.deskconn.account.principal.delete';
  static const String accountPrincipalRotate = 'com.deskconn.account.principal.rotate';

  static const String desktopList = 'com.deskconn.desktop.list';
  static const String desktopDetach = 'com.deskconn.desktop.detach';
  static const String deviceCreate = 'com.deskconn.device.create';
  static const String deviceDelete = 'com.deskconn.device.delete';

  static const String deskconndAppIcon = 'com.deskconn.app.icon';
  static const String deskconndAppList = 'com.deskconn.app.list';
  static const String deskconndAudioIsMuted = 'com.deskconn.remotecontrol.audio.ismuted';
  static const String deskconndAudioToggleMute = 'com.deskconn.remotecontrol.audio.togglemute';
  static const String deskconndCapabilitiesList = 'com.deskconn.capabilities.list';
  static const String deskconndCapabilitiesWatch = 'com.deskconn.capabilities.watch';
  static const String deskconndMachineInfo = 'com.deskconn.machine.info';
  static const String deskconndManifestGet = 'com.deskconn.manifest.get';
  static const String deskconndFileBrowse = 'com.deskconn.file.browse';
  static const String deskconndFileCopy = 'com.deskconn.file.copy';
  static const String deskconndFileDelete = 'com.deskconn.file.delete';
  static const String deskconndFileRename = 'com.deskconn.file.rename';
  static const String deskconndFileCat = 'com.deskconn.file.cat';
  static const String deskconndFileEdit = 'com.deskconn.file.edit';
  static const String deskconndGitStatus = 'com.deskconn.git.status';
  static const String deskconndGitOriginal = 'com.deskconn.git.original';
  static const String deskconndIndexQuery = 'com.deskconn.media.index.query';
  static const String deskconndKeyExchange = 'com.deskconn.key.exchange';
  static const String deskconndMediaKeyExchange = 'com.deskconn.media.key.exchange';
  static const String deskconndPing = 'com.deskconn.ping';
  static const String deskconndRemoteControlKeyExchange = 'com.deskconn.remotecontrol.key.exchange';
  static const String deskconndMprisNext = 'com.deskconn.remotecontrol.mpris.next';
  static const String deskconndMprisPlayers = 'com.deskconn.remotecontrol.mpris.players';
  static const String deskconndMprisPlayPause = 'com.deskconn.remotecontrol.mpris.playpause';
  static const String deskconndMprisPrevious = 'com.deskconn.remotecontrol.mpris.previous';
  static const String deskconndProcessList = 'com.deskconn.process.list';
  static const String deskconndProcessSignal = 'com.deskconn.process.signal';
  static const String deskconndScreenBrightnessGet = 'com.deskconn.remotecontrol.screen.brightness.get';
  static const String deskconndScreenBrightnessSet = 'com.deskconn.remotecontrol.screen.brightness.set';
  static const String deskconndScreenLock = 'com.deskconn.remotecontrol.screen.lock';
  static const String deskconndScreenshot = 'com.deskconn.remotecontrol.screenshot';
  static const String deskconndShell = 'com.deskconn.shell';
  static const String deskconndWallpaperChecksum = 'com.deskconn.wallpaper.checksum';
  static const String deskconndWallpaperGet = 'com.deskconn.wallpaper.get';

  static const String webrtcOffer = 'com.deskconn.webrtc.offer';
  static const String webrtcAnswererOnCandidate = 'com.deskconn.webrtc.answerer.on_candidate';
  static const String webrtcOffererOnCandidate = 'com.deskconn.webrtc.offerer.on_candidate';
}
