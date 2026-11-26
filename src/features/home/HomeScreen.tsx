/**
 * Home: "Arabam nerede" + detection status + context-dependent permission cards.
 * Presentational only (data and actions come in as props) so CI preview screens can
 * render it with synthetic data.
 */
import type { ParkingRecord } from '../../../modules/carcrumb-detection';
import { InfoRow, PrimaryButton, Screen, SecondaryButton, Section, StatusLabel, TimeRow, Txt } from '../../design/components';
import { statePresentation } from '../detection/presentation';
import { confidenceCopy } from '../parking/presentation';
import { isLocationOff, shouldOfferAlways } from '../permissions/flow';
import type { HomeData } from './useHomeData';

export type HomeActions = {
  onDirections: (park: ParkingRecord) => void;
  onUpgradeAlways: () => void;
  onOpenSettings: () => void;
};

export function HomeScreen({ data, actions }: { data: HomeData; actions: HomeActions }) {
  const location = data.diagnostics?.location;
  const locationOff = location ? isLocationOff(location.authorization, location.servicesEnabled) : false;
  const offerAlways = location ? shouldOfferAlways(location.authorization, data.trips) : false;
  const park = data.parking;
  const alternatives = park && park.confidence === 'low' ? data.recentParkings.filter((p) => p.id !== park.id) : [];
  const state = statePresentation[data.state];

  return (
    <Screen title="CarCrumb">
      {locationOff ? (
        <Section title="Konum kapalı" footer="Kayıtlı park yerin ve geçmişin görünmeye devam eder.">
          <StatusLabel title="Otomatik kayıt kapalı" iconName="locationOff" tone="uncertain" />
          <Txt tone="secondary">
            Yolculuklarını ve park yerini otomatik kaydetmek için Ayarlar'dan CarCrumb'a konum izni ver.
          </Txt>
          <PrimaryButton label="Ayarları aç" iconName="settings" onPress={actions.onOpenSettings} />
        </Section>
      ) : null}

      <Section title="Aracın" footer={park ? confidenceCopy[park.confidence].hint : undefined}>
        {park ? (
          <>
            <StatusLabel
              title={park.confidence === 'high' ? 'Park yeri kayıtlı' : 'Park yeri (tahmini)'}
              iconName="parked"
              tone={park.confidence === 'high' ? 'parked' : 'pending'}
            />
            <TimeRow label="Park edildi" date={new Date(park.parkedAt)} />
            <InfoRow label="Güven" value={confidenceCopy[park.confidence].label} />
            <PrimaryButton label="Yürüyüş rotası" iconName="directions" onPress={() => actions.onDirections(park)} />
          </>
        ) : (
          <>
            <Txt>{data.storeUnavailable ? 'Kayıtlar telefonun kilidi açılınca görünür.' : 'Henüz park kaydı yok.'}</Txt>
            <Txt tone="secondary">Araçtan inip uzaklaştığında park yerin kendiliğinden kaydedilir.</Txt>
          </>
        )}
      </Section>

      {alternatives.length > 0 ? (
        <Section title="Önceki parklar" footer="Son park tahmini ise aracın bunlardan birinde olabilir.">
          {alternatives.map((p) => (
            <ParkAlternative key={p.id} park={p} onDirections={actions.onDirections} />
          ))}
        </Section>
      ) : null}

      {offerAlways ? (
        <Section
          title="Arka planda kayıt"
          footer="Bir sonraki ekranda konum iznini “Her Zaman” olarak değiştirebilirsin.">
          <Txt>Uygulama kapalıyken de yolculuklarını ve park yerini kaydedebilmemiz için konuma her zaman erişim gerekiyor.</Txt>
          <PrimaryButton label="Devam" onPress={actions.onUpgradeAlways} />
        </Section>
      ) : null}

      <Section title="Durum" footer="Konum verilerin yalnızca bu cihazda kalır.">
        <StatusLabel title={state.title} iconName={state.iconName} tone={state.tone} />
        <Txt tone="secondary">{state.description}</Txt>
      </Section>
    </Screen>
  );
}

function ParkAlternative({ park, onDirections }: { park: ParkingRecord; onDirections: (p: ParkingRecord) => void }) {
  return (
    <>
      <TimeRow label={`${confidenceCopy[park.confidence].label} güven`} date={new Date(park.parkedAt)} />
      <SecondaryButton label="Bu parka rota" iconName="directions" onPress={() => onDirections(park)} />
    </>
  );
}
