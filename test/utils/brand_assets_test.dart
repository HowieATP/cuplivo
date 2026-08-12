import 'package:Cuplivo/utils/brand_assets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('BrandAssets', () {
    test('mapped Metaso icon is selectable as a built-in provider avatar', () {
      final asset = BrandAssets.assetForName('metaso');

      expect(asset, 'assets/icons/metaso-color.svg');
      expect(BrandAssets.selectableAssetOrNull(asset!), asset);
    });

    test('maps fish audio names to the fish-audio icon', () {
      expect(
        BrandAssets.assetForName('Fish Audio'),
        'assets/icons/fish-audio.svg',
      );
      expect(
        BrandAssets.assetForName('fishaudio'),
        'assets/icons/fish-audio.svg',
      );
    });

    test('fish-audio icon needs dark invert', () {
      expect(
        BrandAssets.assetNeedsDarkInvert('assets/icons/fish-audio.svg'),
        isTrue,
      );
    });
  });
}
