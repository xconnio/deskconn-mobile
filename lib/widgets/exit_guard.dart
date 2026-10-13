import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';

bool keepFrameworkHandlingBack(NavigationNotification notification) {
  final state = WidgetsBinding.instance.lifecycleState;
  if (state != null && state != AppLifecycleState.detached) {
    SystemNavigator.setFrameworkHandlesBack(true);
  }
  return true;
}
