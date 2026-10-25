import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

/// 今日天气：定位 → Open-Meteo 拉当前温度与天气代码。
///
/// 数据源免费、无需 key（用户拍板 A）；定位用 geolocator 单次定位（用户拍板 B）。
/// 失败一律返回 null，界面层降级隐藏 —— 天气是锦上添花，不能阻塞日历主功能。
class WeatherService {
  static const _endpoint = 'https://api.open-meteo.com/v1/forecast';

  /// 拉当前天气。网络失败 / 解析失败返回 null。
  static Future<WeatherInfo?> fetchWeather(double lat, double lon) async {
    final uri = Uri.parse(_endpoint).replace(queryParameters: {
      'latitude': lat.toStringAsFixed(4),
      'longitude': lon.toStringAsFixed(4),
      'current': 'temperature_2m,weather_code,is_day',
    });
    final res = await _httpGet(uri);
    if (res == null) return null;
    return parseWeather(res);
  }

  /// 解析 Open-Meteo 响应正文。格式不对 / 缺字段返回 null。
  @visibleForTesting
  static WeatherInfo? parseWeather(String body) {
    try {
      final root = jsonDecode(body) as Map<String, dynamic>;
      final current = root['current'] as Map<String, dynamic>?;
      if (current == null) return null;
      final temp = (current['temperature_2m'] as num?)?.toDouble();
      final code = (current['weather_code'] as num?)?.toInt();
      final isDay = (current['is_day'] as num?)?.toInt();
      if (temp == null || code == null) return null;
      return WeatherInfo(
        temperatureC: temp,
        weatherCode: code,
        isDay: isDay != 0,
      );
    } catch (_) {
      return null;
    }
  }

  static Future<String?> _httpGet(Uri uri) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final req = await client.getUrl(uri);
      req.headers.set(HttpHeaders.userAgentHeader, 'DaoBanAssistantPro');
      final res = await req.close();
      if (res.statusCode != HttpStatus.ok) return null;
      return await res.transform(utf8.decoder).join();
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }
}

/// 一条天气快照：温度（℃）+ WMO 天气代码 + 是否白天。
class WeatherInfo {
  const WeatherInfo({
    required this.temperatureC,
    required this.weatherCode,
    required this.isDay,
  });

  final double temperatureC;
  final int weatherCode;
  final bool isDay;

  /// 显示用的温度（取整）。
  String get temperatureText => '${temperatureC.round()}°';
}

/// WMO weather code → Material 图标（白天/夜晚选不同的晴天/月亮）。
IconData weatherIcon(int code, bool isDay) {
  if (code == 0) return isDay ? Icons.wb_sunny_outlined : Icons.nights_stay_outlined;
  if (code == 1 || code == 2) return Icons.wb_cloudy_outlined; // 少云/多云
  if (code == 3) return Icons.cloud_outlined; // 阴
  if (code == 45 || code == 48) return Icons.foggy; // 雾/凇
  if (code >= 51 && code <= 67) return Icons.water_drop_outlined; // 毛毛雨/雨/冻雨
  if (code >= 71 && code <= 77) return Icons.ac_unit; // 雪
  if (code >= 80 && code <= 82) return Icons.umbrella_outlined; // 阵雨
  if (code >= 95) return Icons.thunderstorm_outlined; // 雷暴
  return Icons.wb_cloudy_outlined;
}

/// WMO weather code → l10n 语义 key（由界面层查 [L10n.weatherLabel]）。
String weatherLabelKey(int code) {
  if (code == 0) return 'clear';
  if (code == 1 || code == 2) return 'partlyCloudy';
  if (code == 3) return 'overcast';
  if (code == 45 || code == 48) return 'fog';
  if (code >= 51 && code <= 57) return 'drizzle';
  if (code >= 61 && code <= 67) return 'rain';
  if (code >= 71 && code <= 77) return 'snow';
  if (code >= 80 && code <= 82) return 'showers';
  if (code >= 95) return 'thunderstorm';
  return 'unknown';
}
