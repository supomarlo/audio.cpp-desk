typedef OmniVoiceInstructValue = ({
  String value,
  String en,
  String zh,
});

typedef OmniVoiceInstructGroup = ({
  String id,
  String en,
  String zh,
  List<OmniVoiceInstructValue> values,
});

const List<OmniVoiceInstructGroup> kOmniVoiceInstructGroups = [
  (
    id: 'gender',
    en: 'Gender',
    zh: '性别',
    values: [
      (value: 'male', en: 'male', zh: '男'),
      (value: 'female', en: 'female', zh: '女'),
    ],
  ),
  (
    id: 'age',
    en: 'Age',
    zh: '年龄',
    values: [
      (value: 'child', en: 'child', zh: '儿童'),
      (value: 'teenager', en: 'teenager', zh: '少年'),
      (value: 'young adult', en: 'young adult', zh: '青年'),
      (value: 'middle-aged', en: 'middle-aged', zh: '中年'),
      (value: 'elderly', en: 'elderly', zh: '老年'),
    ],
  ),
  (
    id: 'pitch',
    en: 'Pitch',
    zh: '音调',
    values: [
      (value: 'very low pitch', en: 'very low pitch', zh: '极低音调'),
      (value: 'low pitch', en: 'low pitch', zh: '低音调'),
      (value: 'moderate pitch', en: 'moderate pitch', zh: '中音调'),
      (value: 'high pitch', en: 'high pitch', zh: '高音调'),
      (value: 'very high pitch', en: 'very high pitch', zh: '极高音调'),
    ],
  ),
  (
    id: 'style',
    en: 'Style',
    zh: '风格',
    values: [
      (value: 'whisper', en: 'whisper', zh: '耳语'),
    ],
  ),
  (
    id: 'accent',
    en: 'English accent',
    zh: '英文口音',
    values: [
      (value: 'american accent', en: 'American', zh: '美式'),
      (value: 'british accent', en: 'British', zh: '英式'),
      (value: 'australian accent', en: 'Australian', zh: '澳式'),
      (value: 'canadian accent', en: 'Canadian', zh: '加式'),
      (value: 'indian accent', en: 'Indian', zh: '印度'),
      (value: 'chinese accent', en: 'Chinese', zh: '中式'),
      (value: 'korean accent', en: 'Korean', zh: '韩式'),
      (value: 'japanese accent', en: 'Japanese', zh: '日式'),
      (value: 'portuguese accent', en: 'Portuguese', zh: '葡式'),
      (value: 'russian accent', en: 'Russian', zh: '俄式'),
    ],
  ),
  (
    id: 'dialect',
    en: 'Chinese dialect',
    zh: '中文方言',
    values: [
      (value: '河南话', en: 'Henan', zh: '河南话'),
      (value: '陕西话', en: 'Shaanxi', zh: '陕西话'),
      (value: '四川话', en: 'Sichuan', zh: '四川话'),
      (value: '贵州话', en: 'Guizhou', zh: '贵州话'),
      (value: '云南话', en: 'Yunnan', zh: '云南话'),
      (value: '桂林话', en: 'Guilin', zh: '桂林话'),
      (value: '济南话', en: 'Jinan', zh: '济南话'),
      (value: '石家庄话', en: 'Shijiazhuang', zh: '石家庄话'),
      (value: '甘肃话', en: 'Gansu', zh: '甘肃话'),
      (value: '宁夏话', en: 'Ningxia', zh: '宁夏话'),
      (value: '青岛话', en: 'Qingdao', zh: '青岛话'),
      (value: '东北话', en: 'Northeastern', zh: '东北话'),
    ],
  ),
];
